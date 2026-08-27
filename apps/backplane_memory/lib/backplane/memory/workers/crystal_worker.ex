defmodule Backplane.Memory.Workers.CrystalWorker do
  @moduledoc "Builds one session crystal per exact subject and processing version after gap grace."

  use Oban.Worker,
    queue: :memory_crystals,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:host_id, :session_id, :processing_version]
    ]

  alias Backplane.Memory.{Config, Crystals}
  alias Backplane.Memory.Crystals.ProjectionStore
  alias Backplane.Memory.Projections.{ReadModels, Source}

  @processing_version "crystal-v1"
  @terminal ~w(stopped completed abandoned)
  @execution_timeout_ms 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: args,
        queue: queue,
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    Backplane.Memory.PipelineTelemetry.span("crystal", args, fn ->
      run(args, now(), job_id: id, queue: queue, attempt: attempt, max_attempts: max_attempts)
    end)
  end

  @doc false
  def run(args, %DateTime{} = current_time),
    do: run(args, current_time, enforce_feature_gate: false)

  @doc false
  def run(
        %{
          "host_id" => host_id,
          "session_id" => session_id,
          "processing_version" => @processing_version,
          "input_revision" => expected_revision
        } = args,
        %DateTime{} = current_time,
        opts
      ) do
    with true <- valid?(host_id) and valid?(session_id) and valid?(expected_revision),
         {:ok, %{input_revision: ^expected_revision} = input} <-
           ReadModels.summary_input(host_id, session_id, limit: 100, allow_incomplete: true),
         true <- input.status in @terminal do
      case grace_wait(input, current_time) do
        0 -> execute_build(args, opts)
        seconds -> {:snooze, seconds}
      end
    else
      false ->
        :ok

      {:ok, _newer_input} ->
        ProjectionStore.skipped(host_id, session_id, expected_revision, :stale_input_revision)
        :ok

      {:error, reason} when reason in [:not_found, :session_not_closed, :projection_incomplete] ->
        ProjectionStore.skipped(host_id, session_id, expected_revision, reason)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(_args, %DateTime{}, _opts), do: {:cancel, :invalid_arguments}

  def enqueue(host_id, session_id, input_revision)
      when is_binary(host_id) and is_binary(session_id) and is_binary(input_revision) do
    ProjectionStore.enqueue(host_id, session_id, input_revision, fn ->
      %{
        host_id: host_id,
        session_id: session_id,
        processing_version: @processing_version,
        input_revision: input_revision
      }
      |> new()
      |> Oban.insert()
    end)
    |> case do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build(
         %{
           "host_id" => host_id,
           "session_id" => session_id,
           "input_revision" => input_revision
         },
         opts
       ) do
    build_session_fn =
      Keyword.get(opts, :build_session_fn, fn host, session, revision ->
        Crystals.build_session(host, session, revision,
          enforce_feature_gate: Keyword.get(opts, :enforce_feature_gate, true)
        )
      end)

    case build_session_fn.(host_id, session_id, input_revision) do
      {:ok, crystal} ->
        case ProjectionStore.complete(host_id, session_id, input_revision, crystal) do
          {:ok, {:stale, _newer_state}} -> {:skipped, :stale_input_revision}
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} when reason in [:stale_input_revision, :partition_mismatch] ->
        {:skipped, reason}

      {:error, :summary_not_ready} ->
        {:snooze, 5}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_build(args, opts) do
    supervisor = task_supervisor()

    if task_supervisor_available?(supervisor) do
      execute_build(args, opts, supervisor)
    else
      {:snooze, 1}
    end
  end

  defp execute_build(args, opts, supervisor) do
    timeout = Keyword.get(opts, :timeout_ms, @execution_timeout_ms)
    build_fn = Keyword.get(opts, :build_fn, fn -> build(args, opts) end)
    sandbox_allow_fn = Keyword.get(opts, :sandbox_allow_fn, &allow_sandbox/1)
    attempt = Keyword.get(opts, :attempt, 1)
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    before_running = Keyword.get(opts, :before_running, fn -> :ok end)

    metadata = telemetry_metadata(args, opts)

    result =
      :telemetry.span([:backplane, :memory, :crystal], metadata, fn ->
        result =
          with :ok <- before_running.() do
            case ProjectionStore.running(
                   args["host_id"],
                   args["session_id"],
                   args["input_revision"]
                 ) do
              {:ok, {:stale, _newer_state}} ->
                {:skipped, :stale_input_revision}

              {:ok, _state} ->
                parent = self()

                task =
                  Task.Supervisor.async_nolink(supervisor, fn ->
                    send(parent, {:crystal_task_ready, self()})

                    receive do
                      :crystal_task_run -> build_fn.()
                    end
                  end)

                receive do
                  {:crystal_task_ready, pid} when pid == task.pid -> :ok
                end

                outcome =
                  case authorize_build_task(task, sandbox_allow_fn) do
                    :ok ->
                      send(task.pid, :crystal_task_run)
                      yield_build_task(task, timeout)

                    {:error, _reason} = error ->
                      Task.shutdown(task, :brutal_kill)
                      error

                    value ->
                      Task.shutdown(task, :brutal_kill)
                      {:error, {:sandbox_allow_failed, value}}
                  end

                record_outcome(args, outcome, attempt >= max_attempts)
                outcome

              {:error, reason} ->
                {:error, reason}
            end
          end

        {result, Map.put(metadata, :classification, classification(result))}
      end)

    case result do
      {:skipped, _reason} -> :ok
      other -> other
    end
  end

  defp authorize_build_task(task, sandbox_allow_fn) do
    try do
      sandbox_allow_fn.(task.pid)
    rescue
      exception ->
        stacktrace = __STACKTRACE__
        Task.shutdown(task, :brutal_kill)
        reraise exception, stacktrace
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Task.shutdown(task, :brutal_kill)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp yield_build_task(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, value} ->
        value

      {:exit, _reason} ->
        {:error, :execution_exit}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :execution_timeout}
    end
  end

  defp telemetry_metadata(args, opts) do
    %{
      projector: "crystal",
      subject_type: "captured_session",
      subject_id: Source.subject_id!(args["host_id"], args["session_id"]),
      host_id: args["host_id"],
      session_id: args["session_id"],
      processing_version: @processing_version,
      input_revision: args["input_revision"],
      job_id: Keyword.get(opts, :job_id),
      queue: Keyword.get(opts, :queue, "memory_crystals"),
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 5)
    }
  end

  defp classification(:ok), do: :complete
  defp classification({:snooze, _seconds}), do: :snoozed
  defp classification({:error, :execution_timeout}), do: :timeout
  defp classification({:error, _reason}), do: :failed
  defp classification({:skipped, _reason}), do: :skipped
  defp classification(_result), do: :skipped

  @doc false
  def allow_sandbox(task_pid, repo \\ repo()) do
    if repo.config()[:pool] != Ecto.Adapters.SQL.Sandbox do
      :ok
    else
      [self() | Process.get(:"$callers", [])]
      |> Enum.uniq()
      |> Enum.reduce_while({:error, :sandbox_owner_not_found}, fn parent, _error ->
        case Ecto.Adapters.SQL.Sandbox.allow(repo, parent, task_pid) do
          :ok -> {:halt, :ok}
          {:already, _status} -> {:halt, :ok}
          :not_found -> {:cont, {:error, :sandbox_owner_not_found}}
          value -> {:halt, {:error, {:sandbox_allow_failed, value}}}
        end
      end)
    end
  end

  defp record_outcome(args, {:error, reason}, terminal?) do
    ProjectionStore.failed(
      args["host_id"],
      args["session_id"],
      args["input_revision"],
      reason,
      terminal?
    )
  end

  defp record_outcome(args, {:skipped, reason}, _terminal?) do
    ProjectionStore.skipped(
      args["host_id"],
      args["session_id"],
      args["input_revision"],
      reason
    )
  end

  defp record_outcome(_args, _result, _terminal?), do: :ok

  defp task_supervisor do
    Application.get_env(
      :backplane_memory,
      :crystal_task_supervisor,
      Backplane.Memory.Crystal.TaskSupervisor
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp task_supervisor_available?(supervisor) when is_atom(supervisor),
    do: not is_nil(Process.whereis(supervisor))

  defp task_supervisor_available?(supervisor) when is_pid(supervisor),
    do: Process.alive?(supervisor)

  defp task_supervisor_available?(_supervisor), do: false

  defp grace_wait(input, current_time) do
    boundary = latest(input.ended_at, input.last_event_at)
    deadline = DateTime.add(boundary, Config.event_gap_grace_seconds(), :second)
    max(DateTime.diff(deadline, current_time, :second), 0)
  end

  defp latest(%DateTime{} = first, %DateTime{} = second) do
    if DateTime.compare(first, second) == :lt, do: second, else: first
  end

  defp latest(%DateTime{} = first, nil), do: first
  defp latest(nil, %DateTime{} = second), do: second

  defp valid?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
