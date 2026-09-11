defmodule Backplane.AgentTools.LocalCommand do
  use GenServer

  @behaviour Backplane.AgentRuntime.Command

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Unix-only local command backend using process groups for run-owned cleanup.

  This adapter enforces explicit executables, bounded streaming, deadlines,
  environment allowlists, and process-group termination. It does not provide
  an OS sandbox or network/filesystem isolation. Unsupported platforms fail
  closed before any process is started.
  """

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @completion_retention_ms 5_000

  @impl Backplane.AgentRuntime.Command
  def start(_command, request, _opts) do
    if os_supported?() and process_group_supported?() do
      GenServer.call(__MODULE__, {:start, request})
    else
      {:error, Error.new(:unsupported_capability, "local command backend is not supported")}
    end
  end

  @impl Backplane.AgentRuntime.Command
  def read(_command, _invocation, job, opts) do
    GenServer.call(__MODULE__, {:read, job, Keyword.get(opts, :cursor, 0)})
  end

  @impl Backplane.AgentRuntime.Command
  def cancel(_command, _invocation) do
    GenServer.call(__MODULE__, :cancel_all)
  end

  @impl GenServer
  def init(_state) do
    Process.flag(:trap_exit, true)
    {:ok, %{active: %{}, completed: %{}, workspaces: MapSet.new()}}
  end

  def handle_call({:start, request}, _from, state) do
    executable = request.executable
    args = List.wrap(request.arguments)

    environment =
      Enum.flat_map(request.environment, fn {key, value} ->
        [{String.to_charlist(key), String.to_charlist(value)}]
      end)

    workspace = String.to_charlist(request.workspace)

    if active_workspace?(state, request.workspace) do
      {:reply,
       {:error,
        Error.new(:resource_conflict, "workspace already has an active command",
          details: %{workspace: request.workspace}
        )}, state}
    else
      spawn_opts = [
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:line, 1024},
        {:args, [executable | args]},
        {:env, environment},
        {:cd, workspace}
      ]

      port = Port.open({:spawn_executable, setsid_path!()}, spawn_opts)
      Process.send_after(self(), {:timeout, port}, request.deadline_limit)

      job = %{
        port: port,
        owner_run_id: request.owner_run_id,
        workspace: request.workspace,
        deadline: System.monotonic_time(:millisecond) + request.deadline_limit,
        output_limit: request.output_limit,
        cursor: 0,
        output: [],
        bytes: 0,
        status: :running,
        exit_status: nil
      }

      {:reply, {:ok, job},
       %{
         state
         | active: Map.put(state.active, port, job),
           workspaces: MapSet.put(state.workspaces, request.workspace)
       }}
    end
  end

  @impl GenServer
  def handle_call({:read, job, cursor}, _from, state) do
    case Map.get(state.active, job.port) || Map.get(state.completed, job.port) do
      nil ->
        {:reply, {:error, Error.new(:not_found, "job not found")}, state}

      current ->
        events = Enum.slice(current.output, cursor, length(current.output))

        {:reply,
         {:ok,
          %{
            output: events,
            cursor: length(current.output),
            status: current.status,
            exit_status: current.exit_status,
            output_limit_exceeded?: current.status == :output_limit_exceeded
          }}, state}
    end
  end

  @impl GenServer
  def handle_call(:cancel_all, _from, state) do
    Enum.each(state.active, fn {port, job} -> kill_job(port, job) end)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {mode, data}}}, state)
      when mode in [:eol, :noeol] and is_map_key(state.active, port) do
    job = Map.get(state.active, port)

    if job.bytes + IO.iodata_length(data) > job.output_limit do
      kill_job(port, job)
      {:noreply, complete_job(port, :output_limit_exceeded, state)}
    else
      line = IO.iodata_to_binary(data)
      job = %{job | output: job.output ++ [line], bytes: job.bytes + IO.iodata_length(data)}
      {:noreply, %{state | active: Map.put(state.active, port, job)}}
    end
  end

  @impl GenServer
  def handle_info({port, :closed}, state) when is_map_key(state.active, port) do
    {:noreply, complete_job(port, :closed, state)}
  end

  @impl GenServer
  def handle_info({:timeout, port}, state) do
    job = Map.get(state.active, port)
    kill_job(port, job)
    {:noreply, complete_job(port, :deadline_exceeded, state)}
  end

  @impl GenServer
  def handle_info({:EXIT, port, _reason}, state) when is_map_key(state.active, port) do
    {:noreply, complete_job(port, :exited, state)}
  end

  @impl GenServer
  def handle_info({:cleanup_completed, port}, state) do
    {:noreply, %{state | completed: Map.delete(state.completed, port)}}
  end

  @impl GenServer
  def handle_info({:EXIT, _port, :normal}, state), do: {:noreply, state}

  defp kill_job(port, _job) do
    case :erlang.port_info(port, :connected) do
      :undefined ->
        :ok

      _connected ->
        case :erlang.port_info(port, :os_pid) do
          :undefined ->
            Port.close(port)

          {os_pid_value, _context} ->
            Port.close(port)
            System.cmd("kill", ["-TERM", "-#{os_pid_value}"])
        end
    end
  end

  defp complete_job(port, status, state) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        state

      {job, active} ->
        Process.send_after(self(), {:cleanup_completed, port}, @completion_retention_ms)

        %{
          state
          | active: active,
            completed: Map.put(state.completed, port, %{job | status: status}),
            workspaces: MapSet.delete(state.workspaces, job.workspace)
        }
    end
  end

  defp active_workspace?(state, workspace_key) do
    MapSet.member?(state.workspaces, workspace_key)
  end

  defp setsid_path! do
    case :os.find_executable(~c"setsid") do
      false -> raise "setsid is required for descendant cleanup"
      path -> path
    end
  end

  defp os_supported? do
    case :os.type() do
      {:unix, _os} -> true
      _ -> false
    end
  end

  defp process_group_supported? do
    :os.find_executable(~c"setsid") != false
  end
end
