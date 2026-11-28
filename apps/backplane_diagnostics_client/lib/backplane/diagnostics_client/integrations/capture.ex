defmodule Backplane.DiagnosticsClient.Integrations.Capture do
  @moduledoc "Extracts structured exception evidence while preserving the caller's control flow."

  alias Backplane.DiagnosticsClient.{Context, Reporter}

  @expected ~w(normal killed_by_request cancelled canceled shutdown approval_required)a

  def report(type, kind, reason, frames, opts \\ []) do
    if reporting?() or expected?(reason) do
      :ignored
    else
      Process.put({__MODULE__, :reporting}, true)

      try do
        Reporter.report(evidence(type, kind, reason, frames, opts), opts[:reporter] || Reporter)
      rescue
        _error -> :ignored
      catch
        _kind, _reason -> :ignored
      after
        Process.delete({__MODULE__, :reporting})
      end
    end
  end

  def reporting?, do: Process.get({__MODULE__, :reporting}, false)

  def internal_module?({module, _, _}) when is_atom(module), do: internal_module?(module)

  def internal_module?(module) when is_atom(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, [
      "Elixir.Backplane.Diagnostics",
      "Elixir.Backplane.HostAgent.Diagnostics"
    ])
  end

  def internal_module?(_), do: false

  defp evidence(type, kind, reason, frames, opts) do
    type_label = reason_type(reason)

    stack = frames |> Enum.take(24) |> Enum.flat_map(&safe_frame(&1, opts[:repository_root]))
    subject = opts[:subject] || %{}
    request_id = opts[:request_id] || get_in(Context.current(), ["correlation", "request_id"])
    pid = opts[:pid] || self()
    boot = Reporter.boot_id(opts[:reporter] || Reporter)
    process_id = identifier({boot, :erlang.pid_to_list(pid)})

    hint =
      opts[:occurrence_hint] || get_in(Context.current(), ["correlation", "occurrence_hint"]) ||
        occurrence_hint(type, process_id, request_id, type_label, stack)

    correlation = %{"process_instance" => process_id}

    correlation =
      if is_binary(request_id) and request_id != "",
        do: Map.put(correlation, "request_id", request_id),
        else: correlation

    correlation = if hint, do: Map.put(correlation, "occurrence_hint", hint), else: correlation

    correlation =
      if is_binary(opts[:trace_id]),
        do: Map.put(correlation, "trace_id", opts[:trace_id]),
        else: correlation

    result = %{
      "outcome" => "failure",
      "error_class" => opts[:error_class] || "software_defect",
      "certainty" => "observed"
    }

    result = if is_binary(opts[:phase]), do: Map.put(result, "phase", opts[:phase]), else: result

    event = %{
      "event_type" => type,
      "subject" => subject,
      "correlation" => correlation,
      "result" => result,
      "evidence" => %{
        "exception" => %{
          "type" => type_label,
          "code" => diagnostic_code(kind, opts),
          "stack" => stack
        }
      },
      "quality" => %{
        "stack" => if(stack == [], do: "unavailable", else: "available"),
        "origin" => opts[:origin] || "application"
      }
    }

    case opts[:duration_us] do
      us when is_integer(us) and us >= 0 -> Map.put(event, "duration_us", us)
      _ -> event
    end
  end

  defp diagnostic_code(kind, opts) do
    cond do
      is_binary(opts[:code]) -> opts[:code]
      is_atom(kind) -> Atom.to_string(kind)
      true -> "unknown_exception"
    end
  end

  defp occurrence_hint(_type, pid, request, reason, [first | _]) when is_binary(request),
    do: identifier({pid, request, reason, first})

  defp occurrence_hint(type, pid, nil, _reason, _stack) when type in ~w(exception worker_exit),
    do: identifier({pid, :process_failure})

  defp occurrence_hint(_type, _pid, _request, _reason, _stack), do: nil

  defp identifier(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp expected?(reason) when reason in @expected, do: true
  defp expected?({kind, _context}) when kind in @expected, do: true
  defp expected?(_), do: false

  defp reason_type(%module{}), do: Atom.to_string(module) |> String.trim_leading("Elixir.")
  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_type(_), do: "unknown"

  defp safe_frame({module, name, arity, location}, root)
       when is_atom(module) and is_atom(name) and is_list(location) do
    frame = %{
      "module" => Atom.to_string(module) |> String.trim_leading("Elixir."),
      "function" => Atom.to_string(name)
    }

    frame =
      case arity do
        count when is_integer(count) and count in 0..255 -> Map.put(frame, "arity", count)
        args when is_list(args) -> Map.put(frame, "arity", length(Enum.take(args, 255)))
        _ -> frame
      end

    frame =
      case location[:line] do
        line when is_integer(line) and line > 0 -> Map.put(frame, "line", line)
        _ -> frame
      end

    case relative_file(location[:file], root) do
      nil -> [frame]
      file -> [Map.put(frame, "file", file)]
    end
  end

  defp safe_frame(_, _), do: []

  defp relative_file(path, root) when is_list(path),
    do: path |> Enum.take(1_024) |> List.to_string() |> relative_file(root)

  defp relative_file(path, root) when is_binary(path) do
    candidate = if is_binary(root), do: Path.relative_to(path, root), else: path

    if Path.type(candidate) == :relative and Path.split(candidate) != [] and
         ".." not in Path.split(candidate),
       do: candidate
  end

  defp relative_file(_, _), do: nil
end
