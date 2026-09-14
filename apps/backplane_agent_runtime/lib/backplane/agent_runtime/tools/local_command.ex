defmodule Backplane.AgentRuntime.Tools.LocalCommand do
  use GenServer
  require Logger

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
  @default_cleanup_timeout_ms 750
  @default_shutdown_timeout_ms 750
  @max_cleanup_timeout_ms 4_000
  @max_shutdown_timeout_ms 2_000
  @handshake_prefix "BACKPLANE_LOCAL_COMMAND"
  @cleanup_poll_ms 10
  @term_grace_ms 150
  @kill_grace_ms 300
  @output_entry_overhead 8

  def start_link(opts \\ []) do
    with {:ok, _config} <- runtime_options(opts) do
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)

      case name do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    end
  end

  @impl Backplane.AgentRuntime.Command
  def start(command, request, _opts) do
    if supported?() do
      GenServer.call(server(command), {:start, request}, request.deadline_limit + 1_000)
    else
      {:error, Error.new(:unsupported_capability, "local command backend is not supported")}
    end
  end

  @impl Backplane.AgentRuntime.Command
  def read(command, _invocation, job, opts) do
    GenServer.call(server(command), {:read, job, Keyword.get(opts, :cursor, 0)})
  end

  @impl Backplane.AgentRuntime.Command
  def cancel(command, invocation) do
    GenServer.call(server(command), {:cancel_owner, invocation.owner_run_id})
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- runtime_options(opts),
         {:ok, cleanup_supervisor} <- Task.Supervisor.start_link() do
      {:ok,
       %{
         active: %{},
         completed: %{},
         pending: %{},
         workspaces: MapSet.new(),
         owned_groups: %{},
         cleanup_supervisor: cleanup_supervisor,
         cleanup_timeout: config.cleanup_timeout,
         shutdown_timeout: config.shutdown_timeout,
         completion_retention: config.completion_retention,
         cleanup_reconciler: config.cleanup_reconciler,
         launcher_script:
           Keyword.get(
             opts,
             :launcher_script,
             Application.app_dir(:backplane_agent_runtime, "priv/local_command_launcher.sh")
           ),
         startup_timeout: Keyword.get(opts, :startup_timeout, @default_startup_timeout_ms)
       }}
    else
      {:error, %Error{} = error} -> {:stop, {:shutdown, error}}
    end
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
        :exit_status,
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
            termination_status: current.termination_status,
            cleanup_status: current.cleanup_status,
            cleanup_error: current.cleanup_error,
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

    state =
      state.active
      |> Enum.filter(fn {_port, job} -> job.owner_run_id == owner_run_id end)
      |> Enum.reduce(state, fn {port, _job}, current ->
        request_cleanup(port, :cancelled, current)
      end)

    {:reply, :ok, state}
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
        timer: timer,
        settle_timer: nil,
        terminal_status: nil,
        cleanup_token: nil,
        cleanup_task_pid: nil,
        cleanup_task_ref: nil,
        cleanup_timer: nil,
        completion_token: nil,
        cleanup_status: :not_started,
        cleanup_error: nil,
        termination_status: :not_requested,
        port_closed?: false
      }

      GenServer.reply(
        pending.from,
        {:ok,
         Map.drop(job, [
           :process_group_id,
           :timer,
           :settle_timer,
           :cleanup_token,
           :cleanup_task_pid,
           :cleanup_task_ref,
           :cleanup_timer
         ])}
      )

      {:noreply,
       %{
         state
         | pending: Map.delete(state.pending, port),
           active: Map.put(state.active, port, job),
           owned_groups:
             Map.put(state.owned_groups, port, %{
               process_group_id: pid,
               workspace: pending.request.workspace
             })
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
    line = IO.iodata_to_binary(data)
    size = byte_size(line) + @output_entry_overhead

    if job.bytes + size > job.output_limit do
      {:noreply, request_cleanup(port, :output_limit_exceeded, state)}
    else
      job = %{job | output: job.output ++ [line], bytes: job.bytes + size}
      {:noreply, %{state | active: Map.put(state.active, port, job)}}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)
    cancel_timer(job.settle_timer)
    state = %{state | active: Map.put(state.active, port, %{job | exit_status: status})}
    terminal_status = if status == 0, do: :completed, else: :failed
    {:noreply, request_cleanup(port, terminal_status, state)}
  end

  def handle_info({port, :closed}, state) when is_map_key(state.active, port) do
    {:noreply, mark_port_closed(port, state)}
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
    {:noreply, request_cleanup(port, :deadline_exceeded, state)}
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
    {:noreply, mark_port_closed(port, state)}
  end

  def handle_info({:settle_exit, port}, state) when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)

    if is_nil(job.exit_status) and is_nil(job.cleanup_token) do
      {:noreply, request_cleanup(port, :execution_failure, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:settle_exit, _port}, state), do: {:noreply, state}

  def handle_info({:termination_requested, port, token}, state)
      when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)

    if job.cleanup_token == token do
      updated = %{job | termination_status: :requested}
      {:noreply, %{state | active: Map.put(state.active, port, updated)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:termination_requested, _port, _token}, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case active_cleanup_by_ref(state, ref) do
      {port, _job} ->
        Process.demonitor(ref, [:flush])
        {:noreply, settle_job(port, normalize_cleanup_result(result), state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case active_cleanup_by_ref(state, ref) do
      {port, %{cleanup_task_pid: ^pid}} ->
        error =
          Error.new(:resource_conflict, "local command cleanup worker exited before settlement",
            details: %{reason: inspect(reason)}
          )

        {:noreply, settle_job(port, {:error, error}, state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:cleanup_timeout, port, token, ref}, state)
      when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)

    if job.cleanup_token == token and job.cleanup_task_ref == ref do
      if is_pid(job.cleanup_task_pid) and Process.alive?(job.cleanup_task_pid),
        do: Process.exit(job.cleanup_task_pid, :kill)

      error =
        Error.new(:resource_conflict, "local command cleanup reconciliation timed out",
          details: %{process_group_id: job.process_group_id}
        )

      {:noreply, settle_job(port, {:error, error}, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:cleanup_timeout, _port, _token, _ref}, state), do: {:noreply, state}

  def handle_info({:cleanup_result, port, token, result}, state)
      when is_map_key(state.active, port) do
    job = Map.fetch!(state.active, port)

    if job.cleanup_token == token do
      if is_pid(job.cleanup_task_pid) and Process.alive?(job.cleanup_task_pid),
        do: Process.exit(job.cleanup_task_pid, :kill)

      {:noreply, settle_job(port, normalize_cleanup_result(result), state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:cleanup_result, _port, _token, _result}, state), do: {:noreply, state}

  def handle_info({:cleanup_completed, port, token}, state) do
    completed =
      case Map.get(state.completed, port) do
        %{completion_token: ^token} -> Map.delete(state.completed, port)
        _other -> state.completed
      end

    {:noreply, %{state | completed: completed}}
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}
  def handle_info({_port, :closed}, state), do: {:noreply, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {port, _pending} -> close_port(port) end)

    stop_cleanup_tasks(state.cleanup_supervisor)

    group_ids =
      state.owned_groups
      |> Map.values()
      |> Enum.map(& &1.process_group_id)
      |> Enum.uniq()

    Enum.each(group_ids, &shutdown_signal/1)

    pending_pids = Enum.map(state.pending, fn {_port, pending} -> pending.launcher_pid end)
    reconcile_shutdown(group_ids, pending_pids, state.shutdown_timeout)
    stop_cleanup_supervisor(state.cleanup_supervisor, state.shutdown_timeout)

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

  defp request_cleanup(port, requested_status, state) do
    job = Map.fetch!(state.active, port)
    terminal_status = choose_terminal_status(job.terminal_status, requested_status)
    status = cleanup_pending_status(terminal_status)

    if job.cleanup_token do
      updated = %{job | terminal_status: terminal_status, status: status}
      %{state | active: Map.put(state.active, port, updated)}
    else
      Process.cancel_timer(job.timer)
      token = make_ref()
      owner = self()

      case Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
             state.cleanup_reconciler.(owner, port, token, job.process_group_id)
           end) do
        %Task{pid: task_pid, ref: task_ref} ->
          cleanup_timer =
            Process.send_after(
              self(),
              {:cleanup_timeout, port, token, task_ref},
              state.cleanup_timeout
            )

          updated = %{
            job
            | cleanup_token: token,
              cleanup_task_pid: task_pid,
              cleanup_task_ref: task_ref,
              cleanup_timer: cleanup_timer,
              cleanup_status: :pending,
              terminal_status: terminal_status,
              status: status
          }

          %{state | active: Map.put(state.active, port, updated)}

        other ->
          settle_job(
            port,
            {:error,
             Error.new(:resource_conflict, "local command cleanup could not start", cause: other)},
            %{
              state
              | active: Map.put(state.active, port, %{job | terminal_status: terminal_status})
            }
          )
      end
    end
  end

  defp settle_job(port, cleanup_result, state) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        state

      {job, active} ->
        Process.cancel_timer(job.timer)
        cancel_timer(job.settle_timer)
        cancel_timer(job.cleanup_timer)
        demonitor_cleanup(job.cleanup_task_ref)
        completion_token = make_ref()

        {job, release_workspace?} =
          case cleanup_result do
            :ok ->
              {%{
                 job
                 | status: job.terminal_status,
                   cleanup_status: :confirmed,
                   cleanup_error: nil,
                   completion_token: completion_token
               }, true}

            {:error, %Error{} = error} ->
              {%{
                 job
                 | status: :cleanup_failed,
                   cleanup_status: :uncertain,
                   cleanup_error: error,
                   completion_token: completion_token
               }, false}
          end

        Process.send_after(
          self(),
          {:cleanup_completed, port, completion_token},
          state.completion_retention
        )

        %{
          state
          | active: active,
            completed: Map.put(state.completed, port, job),
            owned_groups:
              if(release_workspace?,
                do: Map.delete(state.owned_groups, port),
                else: state.owned_groups
              ),
            workspaces:
              if(release_workspace?,
                do: MapSet.delete(state.workspaces, job.workspace),
                else: state.workspaces
              )
        }
    end
  end

  defp choose_terminal_status(:cancelled, _requested), do: :cancelled
  defp choose_terminal_status(_current, :cancelled), do: :cancelled

  defp choose_terminal_status(current, requested)
       when current in [:completed, :failed, :execution_failure] and
              requested in [:deadline_exceeded, :output_limit_exceeded],
       do: requested

  defp choose_terminal_status(nil, requested), do: requested
  defp choose_terminal_status(current, _requested), do: current

  defp cleanup_pending_status(:cancelled), do: :cancelling

  defp cleanup_pending_status(status) when status in [:deadline_exceeded, :output_limit_exceeded],
    do: status

  defp cleanup_pending_status(_status), do: :settling

  defp mark_port_closed(port, state) do
    job = Map.fetch!(state.active, port)

    if job.port_closed? do
      state
    else
      settle_timer = Process.send_after(self(), {:settle_exit, port}, 25)
      updated = %{job | port_closed?: true, settle_timer: settle_timer}
      %{state | active: Map.put(state.active, port, updated)}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp demonitor_cleanup(nil), do: :ok

  defp demonitor_cleanup(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp active_cleanup_by_ref(state, ref) do
    Enum.find(state.active, fn {_port, job} -> job.cleanup_task_ref == ref end)
  end

  defp normalize_cleanup_result(:ok), do: :ok
  defp normalize_cleanup_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_cleanup_result(other) do
    {:error,
     Error.new(:resource_conflict, "local command cleanup returned an invalid result",
       details: %{result: inspect(other)}
     )}
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

  defp reconcile_process_group(owner, port, token, process_group_id) do
    case process_group_exists?(process_group_id) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        send(owner, {:termination_requested, port, token})
        terminate = signal_process_group(process_group_id, "-TERM")

        case wait_for_group_absence(process_group_id, @term_grace_ms) do
          :ok ->
            :ok

          {:error, :still_running} ->
            kill = signal_process_group(process_group_id, "-KILL")

            case wait_for_group_absence(process_group_id, @kill_grace_ms) do
              :ok -> :ok
              {:error, reason} -> cleanup_error(process_group_id, terminate, kill, reason)
            end

          {:error, reason} ->
            cleanup_error(process_group_id, terminate, nil, reason)
        end

      {:error, reason} ->
        cleanup_error(process_group_id, nil, nil, reason)
    end
  end

  defp wait_for_group_absence(process_group_id, limit_ms) do
    deadline = System.monotonic_time(:millisecond) + limit_ms
    wait_for_group_absence_until(process_group_id, deadline)
  end

  defp wait_for_group_absence_until(process_group_id, deadline) do
    case process_group_exists?(process_group_id) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :still_running}
        else
          Process.sleep(@cleanup_poll_ms)
          wait_for_group_absence_until(process_group_id, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signal_process_group(process_group_id, signal) do
    System.cmd(kill_path!(), [signal, "--", "-#{process_group_id}"], stderr_to_stdout: true)
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

  defp cleanup_error(process_group_id, terminate, kill, probe_error) do
    details = %{
      process_group_id: process_group_id,
      terminate: inspect(terminate),
      kill: inspect(kill),
      probe_error: inspect(probe_error)
    }

    {:error,
     Error.new(
       :resource_conflict,
       "local command process group cleanup could not be confirmed",
       details: details
     )}
  end

  defp bounded_timeout(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= maximum ->
        {:ok, timeout}

      _other ->
        {:error,
         Error.new(:validation, "#{key} must be a finite positive timeout",
           details: %{maximum: maximum}
         )}
    end
  end

  defp runtime_options(opts) do
    with {:ok, cleanup_timeout} <-
           bounded_timeout(
             opts,
             :cleanup_timeout,
             @default_cleanup_timeout_ms,
             @max_cleanup_timeout_ms
           ),
         {:ok, shutdown_timeout} <-
           bounded_timeout(
             opts,
             :shutdown_timeout,
             @default_shutdown_timeout_ms,
             @max_shutdown_timeout_ms
           ),
         {:ok, completion_retention} <- completion_retention(opts),
         {:ok, cleanup_reconciler} <- cleanup_reconciler(opts) do
      {:ok,
       %{
         cleanup_timeout: cleanup_timeout,
         shutdown_timeout: shutdown_timeout,
         completion_retention: completion_retention,
         cleanup_reconciler: cleanup_reconciler
       }}
    end
  end

  defp completion_retention(opts) do
    case Keyword.get(opts, :completion_retention, @completion_retention_ms) do
      timeout when is_integer(timeout) and timeout >= 0 -> {:ok, timeout}
      _other -> {:error, Error.new(:validation, "completion_retention must be finite")}
    end
  end

  defp cleanup_reconciler(opts) do
    case Keyword.get(opts, :cleanup_reconciler, &reconcile_process_group/4) do
      reconciler when is_function(reconciler, 4) -> {:ok, reconciler}
      _other -> {:error, Error.new(:validation, "cleanup_reconciler must be a function")}
    end
  end

  defp stop_cleanup_tasks(cleanup_supervisor) do
    if Process.alive?(cleanup_supervisor) do
      cleanup_supervisor
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))
    end
  end

  defp shutdown_signal(process_group_id) do
    case safe_signal_process_group(process_group_id, "-KILL") do
      {_output, 0} -> :ok
      result -> Logger.error("local command shutdown signal failed", result: inspect(result))
    end
  end

  defp safe_signal_process_group(process_group_id, signal) do
    signal_process_group(process_group_id, signal)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reconcile_shutdown(group_ids, pending_pids, limit_ms) do
    deadline = System.monotonic_time(:millisecond) + limit_ms
    reconcile_shutdown_until(group_ids, pending_pids, deadline)
  end

  defp reconcile_shutdown_until(group_ids, pending_pids, deadline) do
    remaining_groups = Enum.filter(group_ids, &group_present_or_uncertain?/1)
    remaining_pending = Enum.filter(pending_pids, &File.exists?("/proc/#{&1}"))

    cond do
      remaining_groups == [] and remaining_pending == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.error("local command shutdown cleanup could not be confirmed",
          process_groups: remaining_groups,
          pending_launchers: remaining_pending
        )

        {:error, :cleanup_unconfirmed}

      true ->
        Process.sleep(@cleanup_poll_ms)
        reconcile_shutdown_until(remaining_groups, remaining_pending, deadline)
    end
  end

  defp group_present_or_uncertain?(process_group_id) do
    case process_group_exists?(process_group_id) do
      {:ok, false} -> false
      _present_or_error -> true
    end
  end

  defp stop_cleanup_supervisor(cleanup_supervisor, timeout) do
    if Process.alive?(cleanup_supervisor) do
      Supervisor.stop(cleanup_supervisor, :shutdown, timeout)
    end
  catch
    :exit, reason ->
      Logger.error("local command cleanup supervisor did not stop", reason: inspect(reason))
      :ok
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

  defp server(command), do: Map.get(command, :server) || __MODULE__

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
