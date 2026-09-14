defmodule Backplane.AgentRuntime.Tools.LocalCommand do
  use GenServer

  @behaviour Backplane.AgentRuntime.Command

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Linux local command backend with verified process-group cleanup.

  Commands start behind a fixed launcher handshake. The launcher blocks until
  its process identity has been verified, so a job is returned only after its
  process group is safe to address. This adapter does not provide an OS sandbox;
  commands that create a new session are outside its descendant-cleanup scope.
  """

  @completion_retention_ms 5_000
  @default_startup_timeout_ms 1_000
  @handshake_prefix "BACKPLANE_LOCAL_COMMAND"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Backplane.AgentRuntime.Command
  def start(_command, request, _opts) do
    if supported?() do
      GenServer.call(__MODULE__, {:start, request}, request.deadline_limit + 1_000)
    else
      {:error, Error.new(:unsupported_capability, "local command backend is not supported")}
    end
  end

  @impl Backplane.AgentRuntime.Command
  def read(_command, _invocation, job, opts) do
    GenServer.call(__MODULE__, {:read, job, Keyword.get(opts, :cursor, 0)})
  end

  @impl Backplane.AgentRuntime.Command
  def cancel(_command, invocation) do
    GenServer.call(__MODULE__, {:cancel_owner, invocation.owner_run_id})
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       active: %{},
       completed: %{},
       pending: %{},
       workspaces: MapSet.new(),
       launcher_script:
         Keyword.get(
           opts,
           :launcher_script,
           Application.app_dir(:backplane_agent_runtime, "priv/local_command_launcher.sh")
         ),
       startup_timeout: Keyword.get(opts, :startup_timeout, @default_startup_timeout_ms)
     }}
  end

  @impl GenServer
  def handle_call({:start, request}, from, state) do
    if active_workspace?(state, request.workspace) do
      {:reply,
       {:error,
        Error.new(:resource_conflict, "workspace already has an active command",
          details: %{workspace: request.workspace}
        )}, state}
    else
      nonce = nonce()
      environment = isolated_environment(request.environment)

      spawn_opts = [
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:line, 1024},
        {:args,
         ["--fork", "--wait", sh_path!(), state.launcher_script, nonce, request.executable] ++
           List.wrap(request.arguments)},
        {:env, environment},
        {:cd, request.workspace}
      ]

      port = Port.open({:spawn_executable, setsid_path!()}, spawn_opts)
      {:os_pid, launcher_pid} = :erlang.port_info(port, :os_pid)

      startup_limit = min(state.startup_timeout, request.deadline_limit)
      timer = Process.send_after(self(), {:startup_timeout, port}, startup_limit)

      pending = %{
        from: from,
        request: request,
        nonce: nonce,
        launcher_pid: launcher_pid,
        started_at: System.monotonic_time(:millisecond),
        timer: timer
      }

      {:noreply,
       %{
         state
         | pending: Map.put(state.pending, port, pending),
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
  def handle_call({:cancel_owner, owner_run_id}, _from, state) do
    pending_for_owner =
      Enum.filter(state.pending, fn {_port, launch} ->
        launch.request.owner_run_id == owner_run_id
      end)

    state =
      Enum.reduce(pending_for_owner, state, fn {port, _launch}, current ->
        fail_pending(
          port,
          Error.new(:cancelled, "local command launch was cancelled"),
          current
        )
      end)

    active = Enum.filter(state.active, fn {_port, job} -> job.owner_run_id == owner_run_id end)

    result =
      Enum.reduce_while(active, :ok, fn {port, job}, :ok ->
        case terminate_process_group(port, job) do
          :ok -> {:cont, :ok}
          {:error, _error} = error -> {:halt, error}
        end
      end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, state) when is_map_key(state.pending, port) do
    pending = Map.fetch!(state.pending, port)

    with {:ok, pid} <- parse_handshake(line, pending.nonce),
         :ok <- validate_process_identity(pid, pending.launcher_pid),
         {:ok, remaining} <- remaining_deadline(pending),
         true <- Port.command(port, acknowledgement(pending.nonce, pid)) do
      Process.cancel_timer(pending.timer)
      timer = Process.send_after(self(), {:timeout, port}, remaining)

      job = %{
        port: port,
        process_group_id: pid,
        owner_run_id: pending.request.owner_run_id,
        workspace: pending.request.workspace,
        deadline: System.monotonic_time(:millisecond) + remaining,
        output_limit: pending.request.output_limit,
        cursor: 0,
        output: [],
        bytes: 0,
        status: :running,
        exit_status: nil,
        timer: timer
      }

      GenServer.reply(pending.from, {:ok, Map.drop(job, [:process_group_id, :timer])})

      {:noreply,
       %{
         state
         | pending: Map.delete(state.pending, port),
           active: Map.put(state.active, port, job)
       }}
    else
      {:error, %Error{} = error} ->
        {:noreply, fail_pending(port, error, state)}

      _reason ->
        {:noreply,
         fail_pending(
           port,
           Error.new(:execution_failure, "local command launcher handshake failed"),
           state
         )}
    end
  end

  def handle_info({port, {:data, _data}}, state) when is_map_key(state.pending, port) do
    {:noreply,
     fail_pending(
       port,
       Error.new(:execution_failure, "local command launcher handshake failed"),
       state
     )}
  end

  def handle_info({port, {:data, {mode, data}}}, state)
      when mode in [:eol, :noeol] and is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)
    size = IO.iodata_length(data)

    if job.bytes + size > job.output_limit do
      case terminate_process_group(port, job) do
        :ok -> {:noreply, complete_job(port, :output_limit_exceeded, state)}
        {:error, _error} -> {:noreply, complete_job(port, :cleanup_failed, state)}
      end
    else
      line = IO.iodata_to_binary(data)
      job = %{job | output: job.output ++ [line], bytes: job.bytes + size}
      {:noreply, %{state | active: Map.put(state.active, port, job)}}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)
    {:noreply, %{state | active: Map.put(state.active, port, %{job | exit_status: status})}}
  end

  def handle_info({port, :closed}, state) when is_map_key(state.active, port) do
    {:noreply, complete_job(port, :closed, state)}
  end

  def handle_info({port, :closed}, state) when is_map_key(state.pending, port) do
    {:noreply,
     fail_pending(
       port,
       Error.new(:execution_failure, "local command launcher closed before handshake"),
       state
     )}
  end

  def handle_info({:startup_timeout, port}, state) when is_map_key(state.pending, port) do
    {:noreply,
     fail_pending(port, Error.new(:timeout, "local command launcher handshake timed out"), state)}
  end

  def handle_info({:startup_timeout, _port}, state), do: {:noreply, state}

  def handle_info({:timeout, port}, state) when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)

    case terminate_process_group(port, job) do
      :ok -> {:noreply, complete_job(port, :deadline_exceeded, state)}
      {:error, _error} -> {:noreply, complete_job(port, :cleanup_failed, state)}
    end
  end

  def handle_info({:timeout, _port}, state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, state) when is_map_key(state.pending, port) do
    {:noreply,
     fail_pending(
       port,
       Error.new(:execution_failure, "local command launcher exited before handshake",
         details: %{reason: inspect(reason)}
       ),
       state
     )}
  end

  def handle_info({:EXIT, port, _reason}, state) when is_map_key(state.active, port) do
    {:noreply, complete_job(port, :exited, state)}
  end

  def handle_info({:cleanup_completed, port}, state) do
    {:noreply, %{state | completed: Map.delete(state.completed, port)}}
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}
  def handle_info({_port, :closed}, state), do: {:noreply, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {port, _pending} -> close_port(port) end)
    Enum.each(state.active, fn {port, job} -> terminate_process_group(port, job) end)
    :ok
  end

  defp fail_pending(port, error, state) do
    case Map.pop(state.pending, port) do
      {nil, _pending} ->
        state

      {pending, pending_by_port} ->
        Process.cancel_timer(pending.timer)
        close_port(port)
        GenServer.reply(pending.from, {:error, error})

        %{
          state
          | pending: pending_by_port,
            workspaces: MapSet.delete(state.workspaces, pending.request.workspace)
        }
    end
  end

  defp complete_job(port, status, state) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        state

      {job, active} ->
        Process.cancel_timer(job.timer)
        Process.send_after(self(), {:cleanup_completed, port}, @completion_retention_ms)

        %{
          state
          | active: active,
            completed: Map.put(state.completed, port, %{job | status: status}),
            workspaces: MapSet.delete(state.workspaces, job.workspace)
        }
    end
  end

  defp parse_handshake(line, nonce) do
    case String.split(IO.iodata_to_binary(line), " ", parts: 3) do
      [@handshake_prefix, ^nonce, pid_text] ->
        case Integer.parse(String.trim(pid_text)) do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp validate_process_identity(pid, launcher_pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {:ok, %{parent: ^launcher_pid, group: ^pid, session: ^pid}} <- parse_proc_stat(stat) do
      :ok
    else
      _other -> :error
    end
  end

  defp parse_proc_stat(stat) do
    case String.split(stat, ") ", parts: 2) do
      [_identity, rest] ->
        case String.split(rest) do
          [_state, parent, group, session | _rest] ->
            with {parent, ""} <- Integer.parse(parent),
                 {group, ""} <- Integer.parse(group),
                 {session, ""} <- Integer.parse(session) do
              {:ok, %{parent: parent, group: group, session: session}}
            else
              _other -> :error
            end

          _other ->
            :error
        end

      _other ->
        :error
    end
  end

  defp acknowledgement(nonce, pid) do
    "#{@handshake_prefix} ACK #{nonce} #{pid}\n"
  end

  defp remaining_deadline(pending) do
    elapsed = System.monotonic_time(:millisecond) - pending.started_at
    remaining = pending.request.deadline_limit - elapsed

    if remaining > 0 do
      {:ok, remaining}
    else
      {:error, Error.new(:timeout, "local command deadline elapsed during startup")}
    end
  end

  defp nonce do
    make_ref()
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp isolated_environment(requested) do
    requested_keys = Map.keys(requested) |> MapSet.new()

    removed =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(requested_keys, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    allowed =
      Enum.map(requested, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    removed ++ allowed
  end

  defp terminate_process_group(port, job) do
    close_port(port)
    group = "-#{job.process_group_id}"

    case System.cmd(kill_path!(), ["-TERM", "--", group], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {terminate_output, _status} ->
        case process_group_exists?(job.process_group_id) do
          {:ok, false} ->
            :ok

          {:ok, true} ->
            termination_error(job.process_group_id, terminate_output, nil)

          {:error, probe_error} ->
            termination_error(job.process_group_id, terminate_output, probe_error)
        end
    end
  end

  defp process_group_exists?(process_group_id) do
    Path.wildcard("/proc/[0-9]*/stat")
    |> Enum.reduce_while({:ok, false}, fn path, {:ok, false} ->
      case File.read(path) do
        {:ok, stat} ->
          case parse_proc_stat(stat) do
            {:ok, %{group: ^process_group_id}} -> {:halt, {:ok, true}}
            {:ok, _other} -> {:cont, {:ok, false}}
            :error -> {:halt, {:error, {:malformed_proc_stat, path}}}
          end

        {:error, :enoent} ->
          {:cont, {:ok, false}}

        {:error, reason} ->
          {:halt, {:error, {:proc_stat_unreadable, path, reason}}}
      end
    end)
  end

  defp termination_error(process_group_id, terminate_output, probe_error) do
    details = %{
      process_group_id: process_group_id,
      terminate_output: terminate_output
    }

    details =
      if probe_error, do: Map.put(details, :probe_error, inspect(probe_error)), else: details

    {:error,
     Error.new(:resource_conflict, "local command process group could not be terminated",
       details: details
     )}
  end

  defp close_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp active_workspace?(state, workspace) do
    MapSet.member?(state.workspaces, workspace)
  end

  defp supported? do
    match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") and
      :os.find_executable(~c"setsid") != false and :os.find_executable(~c"sh") != false and
      :os.find_executable(~c"kill") != false
  end

  defp setsid_path!, do: executable_path!(~c"setsid")
  defp sh_path!, do: executable_path!(~c"sh")
  defp kill_path!, do: executable_path!(~c"kill")

  defp executable_path!(name) do
    case :os.find_executable(name) do
      false -> raise "#{name} is required for local command execution"
      path -> List.to_string(path)
    end
  end
end
