defmodule Backplane.HostAgent.Diagnostics.Collectors.Observation do
  @moduledoc false

  alias Backplane.HostAgent.Diagnostics.Collectors.{CrashArtifact, Log, Probes, Resource, Service}
  alias Backplane.HostAgent.Diagnostics.Collectors.Process, as: ProcessProbe

  @down_states ~w(inactive failed exited dead)

  def sample(target, previous, env) do
    service = if target.service, do: Service.sample(target.service, env)
    old_process = previous["process"]
    process = current_process(target, service, old_process, env)
    {process, process_events, process_snapshot} = process_state(target, process, old_process, env)

    {service_events, service_snapshot} =
      service_state(service, previous["service"], process, old_process)

    {log_events, log_cursor, log_status} = log_events(target, previous["log"])

    {artifact_events, artifact_reference, artifact_status} =
      artifact_events(target, previous["artifact"])

    baseline = resource_event(target, process, service, log_status, artifact_status, env)

    records = process_events ++ service_events ++ log_events ++ artifact_events ++ [baseline]

    snapshot = %{
      "process" => process_snapshot,
      "service" => service_snapshot,
      "log" => log_cursor,
      "artifact" => artifact_reference
    }

    {records, snapshot}
  end

  defp current_process(%{pid: pid}, _service, _previous, env) when is_integer(pid),
    do: ProcessProbe.sample(pid, env)

  defp current_process(_target, %{status: status}, %{"pid" => pid, "instance" => original}, env)
       when status in @down_states do
    case ProcessProbe.sample(pid, env) do
      %{instance: different} when different != original -> %{status: :absent}
      process -> process
    end
  end

  defp current_process(_target, %{pid: pid}, _previous, env) when is_integer(pid),
    do: ProcessProbe.sample(pid, env)

  defp current_process(_target, _service, _previous, _env), do: %{status: :unavailable}

  defp process_state(
         %{pid: pid} = target,
         %{instance: instance},
         %{"instance" => prior} = previous,
         _env
       )
       when is_integer(pid) and instance != prior do
    # A new process with the same PID does not belong to a directly registered instance.
    absent = %{status: :absent}
    records = maybe_process_exit(target, previous, "pid_reused")
    {absent, records, Map.put(previous, "status", "exited")}
  end

  defp process_state(target, %{status: state} = current, previous, env) do
    records =
      cond do
        state in [:absent, :exited] ->
          maybe_process_exit(target, previous, "process_disappeared")

        changed_process?(previous, current) and former_process_gone?(previous, env) ->
          maybe_process_exit(target, previous, "service_process_replaced")

        true ->
          []
      end

    snapshot =
      cond do
        state == :running ->
          %{"instance" => current.instance, "pid" => current.pid, "status" => "running"}

        state in [:absent, :exited] and is_map(previous) ->
          Map.put(previous, "status", "exited")

        true ->
          previous
      end

    {current, records, snapshot}
  end

  defp changed_process?(%{"status" => "running", "instance" => previous}, %{instance: current}),
    do: previous != current

  defp changed_process?(_, _), do: false

  defp former_process_gone?(%{"pid" => pid, "instance" => instance}, env) do
    case ProcessProbe.sample(pid, env) do
      %{status: state} when state in [:absent, :exited] -> true
      %{instance: different} -> different != instance
      _ -> false
    end
  end

  defp maybe_process_exit(
         target,
         %{"status" => "running", "instance" => instance, "pid" => pid},
         reason
       ) do
    [
      event(target, "process_exit", "host_process", reason,
        process_instance: instance,
        value: pid,
        metric: "process_pid"
      )
    ]
  end

  defp maybe_process_exit(_target, _, _), do: []

  defp service_state(nil, _previous, _process, _old), do: {[], nil}
  defp service_state(%{status: "unavailable"}, previous, _process, _old), do: {[], previous}

  defp service_state(service, previous, process, old_process) do
    snapshot = %{
      "status" => service.status,
      "restarts" => service.restarts,
      "invocation" => service.invocation
    }

    records =
      cond do
        restarted?(service, previous, process, old_process) ->
          instance = Map.get(process, :instance) || service.invocation

          [
            %{
              fields:
                host_observation("service_restart", "host_service", service.manager, instance)
                |> put_in(
                  ["evidence", "measurements"],
                  metrics("service_restarts", service.restarts)
                )
            }
          ]

        (service.status in @down_states and previous) && previous["status"] == "active" ->
          instance = (old_process && old_process["instance"]) || previous["invocation"]

          [
            %{
              fields:
                host_observation(
                  "process_exit",
                  "host_service",
                  service.exit_reason || "service_stopped",
                  instance
                )
                |> put_in(
                  ["evidence", "measurements"],
                  metrics("service_exit_status", service.exit_status)
                )
            }
          ]

        true ->
          []
      end

    {records, snapshot}
  end

  defp restarted?(%{status: "active"} = service, previous, process, old) when is_map(previous) do
    old_count = previous["restarts"]
    former_invocation = previous["invocation"]

    (is_integer(service.restarts) and is_integer(old_count) and service.restarts > old_count) or
      (is_binary(service.invocation) and is_binary(former_invocation) and
         service.invocation != former_invocation) or
      previous["status"] in @down_states or changed_process?(old, process)
  end

  defp restarted?(_, _, _, _), do: false

  defp log_events(%{log_path: nil}, _cursor), do: {[], nil, nil}

  defp log_events(target, cursor) do
    result = Log.sample(target.log_path, target.rotated_log_path, cursor)

    events =
      for log <- result.records do
        type = if log.kind == "structured_log_errors", do: "log_error", else: "source_gap"
        fields = host_observation(type, "host_log", log.kind, nil)
        fields = put_in(fields, ["evidence", "measurements"], numbers(log.measurements))
        %{id: log.id, fields: fields}
      end

    {events, result.cursor, result.status}
  end

  defp artifact_events(%{crash_path: nil}, _reference), do: {[], nil, nil}

  defp artifact_events(target, reference) do
    case CrashArtifact.sample(target.crash_path) do
      %{status: :available, reference: same} when same == reference ->
        {[], reference, :available}

      %{status: :available} = artifact ->
        fields = host_observation("crash_artifact", "host_crash", "artifact_metadata", nil)
        fields = put_in(fields, ["evidence", "references"], [artifact.reference])

        fields =
          put_in(
            fields,
            ["evidence", "measurements"],
            numbers(%{
              "artifact_bytes" => artifact.bytes,
              "artifact_mtime_unix" => artifact.modified_at
            })
          )

        {[%{fields: fields}], artifact.reference, :available}

      %{status: status} ->
        {[], reference, status}
    end
  end

  defp resource_event(target, process, service, log_status, artifact_status, env) do
    summary = Resource.sample(process, target.disk_path, env)

    breadcrumbs =
      [
        status_breadcrumb("process_state", process.status),
        status_breadcrumb("log_state", log_status),
        status_breadcrumb("artifact_state", artifact_status),
        service_breadcrumb(service)
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(summary.unavailable)
      |> Enum.take(16)

    event(target, "resource_sample", "host_resource", "periodic_observation",
      process_instance: Map.get(process, :instance)
    )
    |> put_in([:fields, "evidence", "measurements"], summary.measurements)
    |> put_in([:fields, "evidence", "breadcrumbs"], breadcrumbs)
  end

  defp service_breadcrumb(nil), do: nil

  defp service_breadcrumb(service),
    do: %{"kind" => service.manager <> "_state", "reference" => service.status}

  defp status_breadcrumb(_kind, nil), do: nil

  defp status_breadcrumb(kind, status),
    do: %{"kind" => kind, "reference" => Atom.to_string(status)}

  defp event(target, type, phase, reason, opts) do
    %{
      id:
        if(type == "process_exit",
          do: Probes.fingerprint({target.id, phase, opts[:process_instance], reason})
        ),
      fields:
        host_observation(type, phase, reason, opts[:process_instance])
        |> put_in(["evidence", "measurements"], metrics(opts[:metric], opts[:value]))
    }
  end

  defp host_observation(type, phase, reason, process) do
    result = %{"phase" => phase, "certainty" => "observed"}

    result =
      case {type, reason} do
        {"process_exit", "oom_kill"} ->
          Map.merge(result, %{"outcome" => "failure", "error_class" => "environment_failure"})

        {"process_exit", _} ->
          Map.merge(result, %{"outcome" => "unknown_outcome", "error_class" => "unknown"})

        _ ->
          result
      end

    fields = %{
      "event_type" => type,
      "quality" => %{"origin" => "host", "stack" => "unavailable"},
      "result" => result,
      "evidence" => %{"exception" => %{"code" => reason}}
    }

    if is_binary(process) do
      correlation = %{"process_instance" => process}

      correlation =
        if type == "process_exit",
          do:
            Map.put(
              correlation,
              "occurrence_hint",
              Probes.fingerprint({:terminal_identity, process})
            ),
          else: correlation

      Map.put(fields, "correlation", correlation)
    else
      fields
    end
  end

  defp metrics(_name, nil), do: []
  defp metrics(name, value), do: [%{"name" => name, "value" => value}]

  defp numbers(values),
    do: Enum.map(values, fn {name, value} -> %{"name" => name, "value" => value} end)
end
