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
  @default_receipt_capacity 256
  @default_session_capacity 256

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
  def write(command, _invocation, job, chars) do
    GenServer.call(server(command), {:write, job, chars})
  end

  @impl Backplane.AgentRuntime.Command
  def cancel(command, invocation) do
    GenServer.call(server(command), {:cancel_owner, invocation.owner_run_id})
  end

  @impl Backplane.AgentRuntime.Command
  def cancel_confirmed(command, invocation, timeout) do
    case Map.get(invocation, :session_id) do
      session_id when is_integer(session_id) ->
        server = server(command)

        with :ok <- GenServer.call(server, {:cancel_session, invocation}) do
          await_session_cleanup(server, invocation, System.monotonic_time(:millisecond) + timeout)
        end

      _ ->
        {:error,
         Error.new(:unknown_outcome, "local command cleanup requires an invocation session")}
    end
  end

  @impl Backplane.AgentRuntime.Command
  def reserve(command, invocation),
    do: GenServer.call(server(command), {:reserve_session, invocation})

  @impl Backplane.AgentRuntime.Command
  def acknowledge_release(command, invocation),
    do: GenServer.call(server(command), {:acknowledge_release, invocation})

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
         cleanup_evidence: %{},
         session_obligations: %{},
         released_sessions: %{},
         released_order: :queue.new(),
         expired_session_floor: 0,
         receipt_capacity: config.receipt_capacity,
         session_capacity: config.session_capacity,
         cancelled_launchers: %{},
         cancelled_sessions: %{},
         cleanup_supervisor: cleanup_supervisor,
         cleanup_timeout: config.cleanup_timeout,
         shutdown_timeout: config.shutdown_timeout,
         completion_retention: config.completion_retention,
         cleanup_reconciler: config.cleanup_reconciler,
         shutdown_signaler: config.shutdown_signaler,
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
    case admit_session(state, request) do
      {:ok, state} -> start_reserved(request, from, state)
      {:error, error} -> {:reply, {:error, error}, fence_refusal(state, request, error)}
    end
  end

  def handle_call({:reserve_session, invocation}, _from, state) do
    case admit_session(state, invocation) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, error} -> {:reply, {:error, error}, fence_refusal(state, invocation, error)}
    end
  end

  def handle_call({:acknowledge_release, invocation}, _from, state) do
    with {:ok, receipt} <- session_identity(state, invocation),
         true <- receipt.status == :confirmed do
      {:reply, :ok, retire_receipt(state, invocation.session_id, receipt)}
    else
      false ->
        {:reply, {:error, Error.new(:unknown_outcome, "session release is not confirmed")}, state}

      error ->
        {:reply, error, state}
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

  def handle_call({:write, job, chars}, _from, state) do
    case Map.get(state.active, job.port) do
      nil ->
        {:reply, {:error, Error.new(:not_found, "job not found")}, state}

      _current ->
        if Port.command(job.port, chars) do
          {:reply, :ok, state}
        else
          {:reply, {:error, Error.new(:execution_failure, "command stdin write failed")}, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:cancel_owner, owner_run_id}, _from, state) do
    state =
      Enum.reduce(state.session_obligations, state, fn
        {session_id, %{owner_run_id: ^owner_run_id, status: :reserved}}, current ->
          session_status(current, %{session_id: session_id}, :confirmed)

        _, current ->
          current
      end)

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

    state =
      state.cleanup_evidence
      |> Enum.filter(fn {_session_id, evidence} -> evidence.owner_run_id == owner_run_id end)
      |> Enum.reduce(state, fn {session_id, _evidence}, current ->
        retry_session_cleanup(session_id, current)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:cancel_session, %{session_id: session_id} = invocation}, _from, state)
      when is_integer(session_id) do
    case ensure_cancellation_identity(state, invocation) do
      {:ok, state} ->
        state =
          case Enum.find(state.pending, fn {_port, launch} ->
                 launch.request.session_id == session_id
               end) do
            {port, _launch} ->
              fail_pending(
                port,
                Error.new(:cancelled, "local command launch was cancelled"),
                state
              )

            nil ->
              case Enum.find(state.active, fn {_port, job} -> job.session_id == session_id end) do
                {port, _job} ->
                  request_cleanup(port, :cancelled, state)

                nil ->
                  case Map.get(state.session_obligations, session_id) do
                    %{status: status} when status in [:reserved, :never_started] ->
                      session_status(state, invocation, :confirmed)

                    _ ->
                      retry_session_cleanup(session_id, state)
                  end
              end
          end

        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:session_cleanup_status, %{} = invocation}, from, state) do
    case session_identity(state, invocation) do
      {:ok, _} -> handle_call({:session_cleanup_status, invocation.session_id}, from, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:session_cleanup_status, session_id}, _from, state)
      when is_integer(session_id) do
    status =
      cond do
        Enum.any?(state.pending, fn {_port, launch} -> launch.request.session_id == session_id end) ->
          :pending

        Enum.any?(state.active, fn {_port, job} -> job.session_id == session_id end) ->
          :pending

        Enum.any?(state.cleanup_evidence, fn {_key, evidence} ->
          evidence.session_id == session_id and evidence.cleanup_status == :pending
        end) ->
          :pending

        Enum.any?(state.completed, fn {_port, job} ->
          job.session_id == session_id and job.cleanup_status == :uncertain
        end) ->
          :uncertain

        Enum.any?(state.cleanup_evidence, fn {_key, evidence} ->
          evidence.session_id == session_id and evidence.cleanup_status == :uncertain
        end) ->
          :uncertain

        Map.has_key?(state.cancelled_sessions, session_id) ->
          pid = Map.fetch!(state.cancelled_sessions, session_id)
          if File.exists?("/proc/#{pid}"), do: :pending, else: :confirmed

        Map.get(state.session_obligations, session_id, %{})[:status] == :confirmed or
            Map.has_key?(state.released_sessions, session_id) ->
          :confirmed

        true ->
          :unknown
      end

    state =
      if status == :confirmed do
        %{state | cancelled_sessions: Map.delete(state.cancelled_sessions, session_id)}
        |> session_status(%{session_id: session_id}, :confirmed)
      else
        state
      end

    {:reply, status, state}
  end

  def handle_call({:owner_cleanup_status, owner_run_id}, _from, state) do
    {launchers, cancelled_launchers} =
      state.cancelled_launchers
      |> Map.get(owner_run_id, MapSet.new())
      |> Enum.split_with(&File.exists?("/proc/#{&1}"))
      |> then(fn {alive, _gone} ->
        {alive,
         if(alive == [],
           do: Map.delete(state.cancelled_launchers, owner_run_id),
           else: Map.put(state.cancelled_launchers, owner_run_id, MapSet.new(alive))
         )}
      end)

    state = %{state | cancelled_launchers: cancelled_launchers}

    pending? =
      Enum.any?(state.pending, fn {_port, pending} ->
        pending.request.owner_run_id == owner_run_id
      end)

    active = Enum.filter(state.active, fn {_port, job} -> job.owner_run_id == owner_run_id end)

    owned =
      Enum.filter(state.owned_groups, fn {_port, group} -> group.owner_run_id == owner_run_id end)

    failed? =
      Enum.any?(state.completed, fn {_port, job} ->
        job.owner_run_id == owner_run_id and job.cleanup_status == :uncertain
      end)

    evidence_failed? =
      Enum.any?(state.cleanup_evidence, fn {_session_id, evidence} ->
        evidence.owner_run_id == owner_run_id and evidence.cleanup_status == :uncertain
      end)

    status =
      cond do
        failed? or evidence_failed? or
            Enum.any?(active, fn {_port, job} -> job.cleanup_status == :uncertain end) ->
          :uncertain

        active != [] or pending? or owned != [] or launchers != [] ->
          :pending

        true ->
          :confirmed
      end

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, state) when is_map_key(state.pending, port) do
    pending = Map.fetch!(state.pending, port)

    with {:ok, pid} <- parse_handshake(line, pending.nonce),
         :ok <- validate_process_identity(pid, pending.launcher_pid),
         :ok <- alive_owner(pending.request),
         {:ok, remaining} <- remaining_deadline(pending),
         true <- Port.command(port, acknowledgement(pending.nonce, pid)) do
      Process.cancel_timer(pending.timer)
      timer = Process.send_after(self(), {:timeout, port}, remaining)

      job = %{
        port: port,
        session_id: pending.session_id,
        owner_incarnation: Map.get(pending.request, :incarnation, 1),
        owner_monitor_ref: pending.owner_monitor_ref,
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
               workspace: pending.request.workspace,
               owner_run_id: pending.request.owner_run_id,
               session_id: pending.session_id,
               owner_incarnation: Map.get(pending.request, :incarnation, 1)
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
        case evidence_cleanup_by_ref(state, ref) do
          {session_id, _evidence} ->
            Process.demonitor(ref, [:flush])
            {:noreply, settle_evidence(session_id, normalize_cleanup_result(result), state)}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case owner_by_ref(state, ref) do
      {:pending, port} ->
        {:noreply, fail_pending(port, Error.new(:cancelled, "command owner stopped"), state)}

      {:active, port} ->
        {:noreply, request_cleanup(port, :cancelled, state)}

      nil ->
        case active_cleanup_by_ref(state, ref) do
          {port, %{cleanup_task_pid: ^pid}} ->
            error =
              Error.new(
                :resource_conflict,
                "local command cleanup worker exited before settlement",
                details: %{reason: inspect(reason)}
              )

            {:noreply, settle_job(port, {:error, error}, state)}

          nil ->
            case evidence_cleanup_by_ref(state, ref) do
              {session_id, %{cleanup_task_pid: ^pid}} ->
                error =
                  Error.new(
                    :resource_conflict,
                    "local command cleanup worker exited before settlement",
                    details: %{reason: inspect(reason)}
                  )

                {:noreply, settle_evidence(session_id, {:error, error}, state)}

              _other ->
                {:noreply, state}
            end

          _other ->
            {:noreply, state}
        end
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

  def handle_info({:cleanup_timeout, {:session, session_id}, token, ref}, state) do
    case Map.get(state.cleanup_evidence, session_id) do
      %{cleanup_token: ^token, cleanup_task_ref: ^ref} = evidence ->
        if is_pid(evidence.cleanup_task_pid) and Process.alive?(evidence.cleanup_task_pid),
          do: Process.exit(evidence.cleanup_task_pid, :kill)

        error = Error.new(:resource_conflict, "local command cleanup reconciliation timed out")
        {:noreply, settle_evidence(session_id, {:error, error}, state)}

      _other ->
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

  def handle_info({:cleanup_result, {:session, session_id}, token, result}, state) do
    case Map.get(state.cleanup_evidence, session_id) do
      %{cleanup_token: ^token} = evidence ->
        if is_pid(evidence.cleanup_task_pid) and Process.alive?(evidence.cleanup_task_pid),
          do: Process.exit(evidence.cleanup_task_pid, :kill)

        {:noreply, settle_evidence(session_id, normalize_cleanup_result(result), state)}

      _other ->
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

    Enum.each(group_ids, &shutdown_signal(&1, state.shutdown_signaler))

    pending_pids = Enum.map(state.pending, fn {_port, pending} -> pending.launcher_pid end)
    reconcile_shutdown(group_ids, pending_pids, state.shutdown_timeout)
    stop_cleanup_supervisor(state.cleanup_supervisor, state.shutdown_timeout)

    :ok
  end

  defp start_reserved(request, from, state) do
    if is_pid(Map.get(request, :owner_pid)) and not Process.alive?(request.owner_pid) do
      {:reply, {:error, Error.new(:cancelled, "command owner is no longer alive")},
       session_status(state, request, :never_started)}
    else
      if active_workspace?(state, request.workspace) do
        {:reply,
         {:error,
          Error.new(:resource_conflict, "workspace already has an active command",
            details: %{workspace: request.workspace}
          )}, session_status(state, request, :never_started)}
      else
        if map_size(state.active) + map_size(state.pending) + map_size(state.completed) +
             map_size(state.cleanup_evidence) >= state.session_capacity do
          {:reply,
           {:error, Error.new(:overloaded, "local command retained resource capacity reached")},
           session_status(state, request, :never_started)}
        else
          state = session_status(state, request, :launching)
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
            session_id: Map.get(request, :session_id),
            launcher_pid: launcher_pid,
            started_at: System.monotonic_time(:millisecond),
            timer: timer,
            owner_monitor_ref:
              if(is_pid(Map.get(request, :owner_pid)), do: Process.monitor(request.owner_pid))
          }

          {:noreply,
           %{
             state
             | pending: Map.put(state.pending, port, pending),
               workspaces: MapSet.put(state.workspaces, request.workspace)
           }}
        end
      end
    end
  end

  defp fail_pending(port, error, state) do
    case Map.pop(state.pending, port) do
      {nil, _pending} ->
        state

      {pending, pending_by_port} ->
        Process.cancel_timer(pending.timer)
        if pending.owner_monitor_ref, do: Process.demonitor(pending.owner_monitor_ref, [:flush])
        close_port(port)
        GenServer.reply(pending.from, {:error, error})

        %{
          state
          | pending: pending_by_port,
            cancelled_launchers:
              Map.update(
                state.cancelled_launchers,
                pending.request.owner_run_id,
                MapSet.new([pending.launcher_pid]),
                &MapSet.put(&1, pending.launcher_pid)
              ),
            cancelled_sessions:
              if(is_integer(pending.session_id),
                do: Map.put(state.cancelled_sessions, pending.session_id, pending.launcher_pid),
                else: state.cancelled_sessions
              ),
            workspaces: MapSet.delete(state.workspaces, pending.request.workspace)
        }
    end
  end

  defp await_session_cleanup(server, invocation, deadline) do
    case GenServer.call(server, {:session_cleanup_status, invocation}) do
      :confirmed ->
        :ok

      :uncertain ->
        {:error, Error.new(:unknown_outcome, "local command cleanup is uncertain")}

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, Error.new(:unknown_outcome, "local command cleanup confirmation timed out")}
        else
          Process.sleep(10)
          await_session_cleanup(server, invocation, deadline)
        end

      :unknown ->
        {:error, Error.new(:unknown_outcome, "local command cleanup identity is unknown")}

      {:error, %Error{}} = error ->
        error
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

      %Task{pid: task_pid, ref: task_ref} =
        Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
          state.cleanup_reconciler.(owner, port, token, job.process_group_id)
        end)

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
    end
  end

  defp retry_session_cleanup(session_id, state) do
    case Map.get(state.cleanup_evidence, session_id) do
      %{cleanup_status: :uncertain, cleanup_task_ref: nil} = evidence ->
        token = make_ref()
        owner = self()

        %Task{pid: task_pid, ref: task_ref} =
          Task.Supervisor.async_nolink(state.cleanup_supervisor, fn ->
            state.cleanup_reconciler.(
              owner,
              {:session, session_id},
              token,
              evidence.process_group_id
            )
          end)

        cleanup_timer =
          Process.send_after(
            self(),
            {:cleanup_timeout, {:session, session_id}, token, task_ref},
            state.cleanup_timeout
          )

        updated = %{
          evidence
          | cleanup_status: :pending,
            cleanup_token: token,
            cleanup_task_pid: task_pid,
            cleanup_task_ref: task_ref,
            cleanup_timer: cleanup_timer
        }

        %{state | cleanup_evidence: Map.put(state.cleanup_evidence, session_id, updated)}

      _other ->
        state
    end
  end

  defp settle_job(port, cleanup_result, state) do
    case Map.pop(state.active, port) do
      {nil, _active} ->
        state

      {job, active} ->
        if job.owner_monitor_ref, do: Process.demonitor(job.owner_monitor_ref, [:flush])
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

        state = %{
          state
          | active: active,
            completed: Map.put(state.completed, port, job),
            cleanup_evidence:
              cond do
                not is_integer(job.session_id) -> state.cleanup_evidence
                release_workspace? -> Map.delete(state.cleanup_evidence, job.session_id)
                true -> Map.put(state.cleanup_evidence, job.session_id, cleanup_evidence(job))
              end,
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

        if release_workspace?, do: session_status(state, job, :confirmed), else: state
    end
  end

  defp settle_evidence(session_id, cleanup_result, state) do
    case Map.pop(state.cleanup_evidence, session_id) do
      {nil, _evidence} ->
        state

      {evidence, remaining} ->
        cancel_timer(evidence.cleanup_timer)
        demonitor_cleanup(evidence.cleanup_task_ref)

        case cleanup_result do
          :ok ->
            completed =
              Map.new(state.completed, fn {port, job} ->
                if job.session_id == session_id and job.owner_run_id == evidence.owner_run_id and
                     job.owner_incarnation == evidence.owner_incarnation do
                  {port, %{job | cleanup_status: :confirmed}}
                else
                  {port, job}
                end
              end)

            %{
              state
              | cleanup_evidence: remaining,
                completed: completed,
                owned_groups: drop_owned_group(state.owned_groups, session_id),
                workspaces: MapSet.delete(state.workspaces, evidence.workspace)
            }
            |> session_status(evidence, :confirmed)

          {:error, %Error{} = error} ->
            retained = %{
              evidence
              | cleanup_status: :uncertain,
                cleanup_error: error,
                cleanup_token: nil,
                cleanup_task_pid: nil,
                cleanup_task_ref: nil,
                cleanup_timer: nil
            }

            %{state | cleanup_evidence: Map.put(remaining, session_id, retained)}
        end
    end
  end

  defp cleanup_evidence(job) do
    %{
      session_id: job.session_id,
      owner_run_id: job.owner_run_id,
      owner_incarnation: job.owner_incarnation,
      process_group_id: job.process_group_id,
      workspace: job.workspace,
      cleanup_status: :uncertain,
      cleanup_error: job.cleanup_error,
      cleanup_token: nil,
      cleanup_task_pid: nil,
      cleanup_task_ref: nil,
      cleanup_timer: nil
    }
  end

  defp drop_owned_group(owned_groups, session_id) do
    owned_groups
    |> Enum.reject(fn {_port, group} -> Map.get(group, :session_id) == session_id end)
    |> Map.new()
  end

  defp alive_owner(%{owner_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid),
      do: :ok,
      else: {:error, Error.new(:cancelled, "command owner stopped during launch")}
  end

  defp alive_owner(_), do: :ok

  defp owner_by_ref(state, ref) do
    cond do
      pending =
          Enum.find(state.pending, fn {_port, launch} -> launch.owner_monitor_ref == ref end) ->
        {:pending, elem(pending, 0)}

      active = Enum.find(state.active, fn {_port, job} -> job.owner_monitor_ref == ref end) ->
        {:active, elem(active, 0)}

      true ->
        nil
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

  defp evidence_cleanup_by_ref(state, ref) do
    Enum.find(state.cleanup_evidence, fn {_session_id, evidence} ->
      evidence.cleanup_task_ref == ref
    end)
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

  # Live obligations are never evicted. Only explicitly consumed confirmation
  # receipts enter the recent cache; the scalar floor fences expired identities
  # without keeping an expired-ID tombstone collection. Existing reservations
  # are looked up first, so out-of-order acknowledgement cannot revoke them.
  defp admit_session(state, %{session_id: id} = invocation) when is_integer(id) and id > 0 do
    case session_identity(state, invocation) do
      {:ok, %{status: :reserved}} ->
        {:ok, state}

      {:ok, _} ->
        {:error, Error.new(:cancelled, "command session no longer accepts launch")}

      {:error, %Error{details: %{receipt: :expired}}} ->
        {:error, Error.new(:cancelled, "command session identity has expired")}

      {:error, %Error{class: :not_found}} ->
        if map_size(state.session_obligations) < state.session_capacity do
          receipt = %{
            owner_run_id: invocation.owner_run_id,
            incarnation: Map.get(invocation, :incarnation, 1),
            status: :reserved
          }

          {:ok, %{state | session_obligations: Map.put(state.session_obligations, id, receipt)}}
        else
          {:error,
           Error.new(:overloaded, "local command unresolved session capacity reached",
             details: %{launch_status: :never_started, reservation: :not_created}
           )}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp admit_session(state, %{session_id: nil}), do: {:ok, state}

  defp admit_session(state, invocation) when not is_map_key(invocation, :session_id),
    do: {:ok, state}

  defp admit_session(_state, _invocation),
    do: {:error, Error.new(:validation, "command session must be positive")}

  defp session_identity(state, %{session_id: id, owner_run_id: owner} = invocation) do
    case Map.get(state.session_obligations, id) || Map.get(state.released_sessions, id) do
      %{owner_run_id: actual, incarnation: incarnation} = receipt ->
        cond do
          owner != actual ->
            {:error, Error.new(:forbidden, "command session owner does not match")}

          Map.get(invocation, :incarnation, 1) != incarnation ->
            {:error, Error.new(:resource_conflict, "stale command session incarnation")}

          true ->
            {:ok, receipt}
        end

      nil ->
        if is_integer(id) and id <= state.expired_session_floor,
          do:
            {:error,
             Error.new(:unknown_outcome, "command release receipt is unavailable or expired",
               details: %{receipt: :expired}
             )},
          else: {:error, Error.new(:not_found, "command session identity is unknown")}
    end
  end

  defp session_identity(_state, _invocation),
    do: {:error, Error.new(:validation, "command session identity is required")}

  defp fence_refusal(state, %{session_id: id}, %Error{
         details: %{launch_status: :never_started, reservation: :not_created}
       }),
       do: %{state | expired_session_floor: max(state.expired_session_floor, id)}

  defp fence_refusal(state, _invocation, _error), do: state

  defp ensure_cancellation_identity(state, invocation) do
    case session_identity(state, invocation) do
      {:ok, _} ->
        {:ok, state}

      {:error, %Error{class: :not_found}} ->
        case admit_session(state, invocation) do
          {:ok, next} -> {:ok, session_status(next, invocation, :fenced_unknown)}
          error -> error
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp session_status(state, %{session_id: id}, status) when is_integer(id) do
    case Map.get(state.session_obligations, id) do
      nil ->
        state

      receipt ->
        %{
          state
          | session_obligations:
              Map.put(state.session_obligations, id, %{receipt | status: status})
        }
    end
  end

  defp session_status(state, _invocation, _status), do: state

  defp retire_receipt(state, id, receipt) do
    if Map.has_key?(state.released_sessions, id) do
      state
    else
      receipts = Map.put(state.released_sessions, id, receipt)
      order = :queue.in(id, state.released_order)

      {receipts, order, floor} =
        if map_size(receipts) > state.receipt_capacity do
          {{:value, expired}, order} = :queue.out(order)
          {Map.delete(receipts, expired), order, max(state.expired_session_floor, expired)}
        else
          {receipts, order, state.expired_session_floor}
        end

      %{
        state
        | session_obligations: Map.delete(state.session_obligations, id),
          released_sessions: receipts,
          released_order: order,
          expired_session_floor: floor
      }
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
         {:ok, cleanup_reconciler} <- cleanup_reconciler(opts),
         {:ok, shutdown_signaler} <- shutdown_signaler(opts),
         {:ok, receipt_capacity} <- capacity(opts, :receipt_capacity, @default_receipt_capacity),
         {:ok, session_capacity} <- capacity(opts, :session_capacity, @default_session_capacity) do
      {:ok,
       %{
         cleanup_timeout: cleanup_timeout,
         shutdown_timeout: shutdown_timeout,
         completion_retention: completion_retention,
         cleanup_reconciler: cleanup_reconciler,
         shutdown_signaler: shutdown_signaler,
         receipt_capacity: receipt_capacity,
         session_capacity: session_capacity
       }}
    end
  end

  defp capacity(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, Error.new(:validation, "#{key} must be finite and positive")}
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

  defp shutdown_signaler(opts) do
    case Keyword.get(opts, :shutdown_signaler, &signal_process_group/2) do
      signaler when is_function(signaler, 2) -> {:ok, signaler}
      _other -> {:error, Error.new(:validation, "shutdown_signaler must be a function")}
    end
  end

  defp stop_cleanup_tasks(cleanup_supervisor) do
    if Process.alive?(cleanup_supervisor) do
      cleanup_supervisor
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))
    end
  end

  defp shutdown_signal(process_group_id, signaler) do
    case process_group_exists?(process_group_id) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        signal_existing_group(process_group_id, signaler)

      {:error, reason} ->
        Logger.error("local command shutdown group probe failed",
          process_group_id: process_group_id,
          reason: inspect(reason)
        )
    end
  end

  defp signal_existing_group(process_group_id, signaler) do
    case safe_shutdown_signal(signaler, process_group_id, "-KILL") do
      {_output, 0} ->
        :ok

      result ->
        case process_group_exists?(process_group_id) do
          {:ok, false} ->
            :ok

          probe_result ->
            Logger.error("local command shutdown signal failed",
              process_group_id: process_group_id,
              result: inspect(result),
              probe: inspect(probe_result)
            )
        end
    end
  end

  defp safe_shutdown_signal(signaler, process_group_id, signal) do
    signaler.(process_group_id, signal)
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
