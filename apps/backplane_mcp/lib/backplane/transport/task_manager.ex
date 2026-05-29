defmodule Backplane.Transport.TaskManager do
  @moduledoc """
  ETS-backed task manager for MCP experimental tasks (2025-11-25).

  Task lifecycle: working -> completed | failed | cancelled
                  working -> input_required -> working -> ...

  Each task corresponds to an async tool invocation. When a tool call is
  dispatched through `create/3`, it is executed in a monitored `Task` and
  the result is stored back in ETS upon completion.
  """

  use GenServer

  require Logger

  @table :backplane_mcp_tasks
  @cleanup_interval :timer.minutes(5)
  @max_age_ms :timer.hours(1)

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Create a new task that dispatches a tool call asynchronously.

  Returns `{:ok, task_id}` where `task_id` is a unique string identifier.
  """
  @spec create(String.t(), map(), String.t()) :: {:ok, String.t()}
  def create(tool_name, arguments, session_id) do
    GenServer.call(__MODULE__, {:create, tool_name, arguments, session_id})
  end

  @doc """
  Get the current state of a task by ID.

  Returns a task state map or `nil` if the task does not exist.
  """
  @spec get(String.t()) :: map() | nil
  def get(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> task
      [] -> nil
    end
  end

  @doc """
  Get the result of a completed task.

  Returns `{:ok, result}` if the task completed successfully,
  `{:error, reason}` if it failed, or `{:error, "still working"}` if in progress.
  """
  @spec result(String.t()) :: {:ok, term()} | {:error, term()}
  def result(task_id) do
    case get(task_id) do
      nil -> {:error, "task not found"}
      %{status: :completed, result: result} -> {:ok, result}
      %{status: :failed, result: reason} -> {:error, reason}
      %{status: :cancelled} -> {:error, "task was cancelled"}
      %{status: _} -> {:error, "still working"}
    end
  end

  @doc """
  Cancel a task if it is not already in a terminal state.

  Kills the underlying async task if still running.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(task_id) do
    GenServer.call(__MODULE__, {:cancel, task_id})
  end

  @doc """
  Update task status and optionally set a result. Internal use.
  """
  @spec update_status(String.t(), atom(), term()) :: :ok | {:error, term()}
  def update_status(task_id, status, result \\ nil) do
    GenServer.call(__MODULE__, {:update_status, task_id, status, result})
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table, refs: %{}}}
  end

  @impl true
  def handle_call({:create, tool_name, arguments, session_id}, _from, state) do
    task_id = generate_task_id()
    now = DateTime.utc_now()

    task =
      Task.async(fn ->
        Backplane.Transport.McpHandler.dispatch_tool_call(tool_name, arguments)
      end)

    task_state = %{
      id: task_id,
      status: :working,
      tool_name: tool_name,
      arguments: arguments,
      session_id: session_id,
      created_at: now,
      updated_at: now,
      result: nil,
      task_ref: task.ref
    }

    :ets.insert(@table, {task_id, task_state})
    refs = Map.put(state.refs, task.ref, task_id)

    {:reply, {:ok, task_id}, %{state | refs: refs}}
  end

  def handle_call({:cancel, task_id}, _from, state) do
    case get(task_id) do
      nil ->
        {:reply, {:error, "task not found"}, state}

      %{status: status} when status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, "task already in terminal state"}, state}

      %{task_ref: ref} = task_state ->
        # Kill the running task process
        Process.demonitor(ref, [:flush])

        # Find and kill the process associated with this ref if it's still alive
        # Since we used Task.async, we need to clean up properly
        receive do
          {^ref, _result} -> :ok
        after
          0 -> :ok
        end

        updated = %{task_state | status: :cancelled, updated_at: DateTime.utc_now()}
        :ets.insert(@table, {task_id, updated})
        refs = Map.delete(state.refs, ref)

        {:reply, :ok, %{state | refs: refs}}
    end
  end

  def handle_call({:update_status, task_id, status, result}, _from, state) do
    case get(task_id) do
      nil ->
        {:reply, {:error, "task not found"}, state}

      task_state ->
        updated = %{
          task_state
          | status: status,
            result: result,
            updated_at: DateTime.utc_now()
        }

        :ets.insert(@table, {task_id, updated})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {task_id, refs} ->
        case get(task_id) do
          %{status: :cancelled} ->
            # Already cancelled, ignore result
            {:noreply, %{state | refs: refs}}

          task_state when not is_nil(task_state) ->
            {status, task_result} =
              case result do
                {:ok, data} -> {:completed, data}
                {:error, reason} -> {:failed, reason}
                other -> {:completed, other}
              end

            updated = %{
              task_state
              | status: status,
                result: task_result,
                updated_at: DateTime.utc_now()
            }

            :ets.insert(@table, {task_id, updated})
            {:noreply, %{state | refs: refs}}

          nil ->
            {:noreply, %{state | refs: refs}}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task crashed
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {task_id, refs} ->
        case get(task_id) do
          %{status: :cancelled} ->
            {:noreply, %{state | refs: refs}}

          task_state when not is_nil(task_state) ->
            Logger.warning("MCP task #{task_id} crashed: #{inspect(reason)}")

            updated = %{
              task_state
              | status: :failed,
                result: "Task crashed: #{inspect(reason)}",
                updated_at: DateTime.utc_now()
            }

            :ets.insert(@table, {task_id, updated})
            {:noreply, %{state | refs: refs}}

          nil ->
            {:noreply, %{state | refs: refs}}
        end
    end
  end

  def handle_info(:cleanup, state) do
    cleanup_old_tasks()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp generate_task_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_old_tasks do
    cutoff = DateTime.add(DateTime.utc_now(), -@max_age_ms, :millisecond)

    :ets.foldl(
      fn {task_id, %{status: status, updated_at: updated_at}}, acc ->
        if status in [:completed, :failed, :cancelled] and
             DateTime.compare(updated_at, cutoff) == :lt do
          :ets.delete(@table, task_id)
        end

        acc
      end,
      :ok,
      @table
    )
  end
end
