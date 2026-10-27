defmodule Backplane.AgentRuntime.Plugins.Session do
  @moduledoc """
  Activates one immutable plugin installation for one run.

  Adapter activation, calls and cleanup run in owned supervised workers. A close
  seals admission and retains one bounded cleanup attempt for every activation.
  Unconfirmed cleanup keeps the Session inspectable; only confirmed stop retires
  its coordinator. Reports are process-local evidence, not crash recovery.
  """
  use GenServer
  alias Backplane.AgentRuntime.{Error, Execution, ToolCatalog}
  alias Backplane.AgentRuntime.Plugins.{Backend, MCP}
  alias Backplane.PluginProtocol
  alias Backplane.AgentRuntime.Codex.PathGuard

  def start_link(opts) do
    with {:ok, session} <- GenServer.start_link(__MODULE__, opts) do
      # Timers in the live coordinator bound activation and failed-catalog cleanup.
      :ready = GenServer.call(session, :await_activation, :infinity)
      {:ok, session}
    end
  end

  def snapshot(session), do: GenServer.call(session, :snapshot)
  def catalog(session, run_id), do: GenServer.call(session, {:catalog, run_id})
  def load_skill(session, run_id, path), do: GenServer.call(session, {:skill, run_id, path})
  def resource(session, run_id, path), do: GenServer.call(session, {:resource, run_id, path})

  def call_tool(session, run_id, name, arguments),
    do: GenServer.call(session, {:call, run_id, name, arguments}, :infinity)

  def close(session, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    cleanup = Keyword.get(opts, :cleanup_timeout)

    if observation_timeout?(timeout) and (is_nil(cleanup) or finite_timeout?(cleanup)) do
      GenServer.call(session, {:close, cleanup, timeout}, :infinity)
    else
      {:error, Error.new(:validation, "invalid plugin close timeout")}
    end
  end

  def cleanup_status(session), do: GenServer.call(session, :cleanup_status)

  def stop(session) do
    case close(session) do
      {:ok, %{outcome: :confirmed}} ->
        GenServer.call(session, :stop_confirmed, :infinity)

      {:ok, report} ->
        {:error,
         Error.new(:unknown_outcome, "plugin cleanup is unconfirmed",
           details: %{close_id: report.close_id, report: report}
         )}

      error ->
        error
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    installation = Keyword.fetch!(opts, :installation)
    root_input = Path.expand(Map.fetch!(installation, :root))
    data_input = Path.expand(Map.fetch!(installation, :data_dir))
    run_id = Keyword.fetch!(opts, :run_id)
    timeout = Keyword.get(opts, :timeout, 5_000)

    with true <- Map.get(installation, :enabled, true),
         true <- is_binary(run_id) and run_id != "" and finite_timeout?(timeout),
         {:ok, _limits} <- Execution.validate_limits(Keyword.take(opts, [:cleanup_timeout])),
         {:ok, root} <- PathGuard.authorize(root_input, root_input),
         :ok <- File.mkdir_p(data_input),
         {:ok, data_dir} <- PathGuard.authorize(data_input, data_input),
         true <-
           root != data_dir and not String.starts_with?(data_dir, root <> "/") and
             not String.starts_with?(root, data_dir <> "/"),
         {:ok, package} <- PluginProtocol.load_directory(root),
         :ok <- verify_installation(root, installation) do
      {:ok, supervisor} = Task.Supervisor.start_link()

      env =
        Keyword.get(opts, :env, %{})
        |> Map.merge(%{"PLUGIN_ROOT" => root, "PLUGIN_DATA" => data_dir})

      components =
        Map.new(package.mcp_servers, fn {name, _} ->
          {name,
           %{
             status: :starting,
             tools: 0,
             activation_id: id("activation"),
             outcome: :pending,
             activation_error: nil,
             cleanup: nil,
             allocation: :pending,
             cleanup_started: false,
             cleanup_id: nil,
             owner_ref: nil
           }}
        end)

      state = %{
        session: self(),
        run_id: run_id,
        installation: installation,
        root: root,
        data_dir: data_dir,
        package: package,
        connections: %{},
        tools: %{},
        components: components,
        diagnostics: package.diagnostics,
        adapter: Keyword.get(opts, :mcp_adapter, MCP),
        timeout: timeout,
        cleanup_timeout: Keyword.get(opts, :cleanup_timeout, 5_000),
        bindings: Keyword.get(opts, :bindings, %{}),
        adapter_options: Keyword.take(opts, [:guardian_path]),
        env: env,
        supervisor: supervisor,
        jobs: %{},
        calls: %{},
        monitors: %{},
        activation_deadline: now() + timeout,
        ready_waiters: [],
        close_waiters: %{},
        phase: :active,
        close_id: nil,
        close_deadline: nil,
        close_timer: nil,
        redactions: strings([Keyword.get(opts, :env, %{}), Keyword.get(opts, :bindings, %{})])
      }

      {:ok, state, {:continue, :activate}}
    else
      false -> {:stop, :invalid_plugin_session}
      {:error, reason} -> {:stop, {:plugin_load_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:activate, state) do
    state =
      Enum.reduce(state.package.mcp_servers, state, fn {name, config}, acc ->
        activation = acc.components[name].activation_id
        owner = self()

        opts =
          [
            session: owner,
            server: name,
            activation_id: activation,
            root: acc.root,
            data_dir: acc.data_dir,
            env: acc.env,
            timeout: acc.timeout
          ] ++ acc.adapter_options

        start_job(acc, {:start, name}, acc.activation_deadline, fn ->
          result =
            with {:ok, expanded} <- expand_config(config, acc.env) do
              acc.adapter.start(bind(expanded, Map.get(acc.bindings, name, %{})), opts)
            else
              {:error, reason} -> {:not_allocated, reason}
            end

          case result do
            {:ok, connection} ->
              :accepted =
                GenServer.call(
                  owner,
                  {:activation_started, name, activation, self(), connection},
                  :infinity
                )

              receive do: ({:retire_activation, ^activation} -> :owner_retired)

            other ->
              other
          end
        end)
      end)

    {:noreply, ready(state)}
  end

  @impl true
  def handle_call(:await_activation, from, state) do
    {:noreply, ready(%{state | ready_waiters: [from | state.ready_waiters]})}
  end

  def handle_call({:activation_started, name, activation, worker, connection}, _from, state) do
    case Enum.find(state.jobs, fn {_ref, job} ->
           job.role == {:start, name} and job.task.pid == worker
         end) do
      {ref, job} when state.phase == :active ->
        if state.components[name].activation_id == activation do
          cancel_timer(job.timer)

          component = %{
            state.components[name]
            | allocation: :acknowledged,
              owner_ref: ref,
              status: :catalog
          }

          state = %{
            state
            | connections: Map.put(state.connections, name, connection),
              jobs: Map.put(state.jobs, ref, %{job | role: {:owner, name}, timer: nil}),
              components: Map.put(state.components, name, component)
          }

          state = monitor_connection(state, name, connection)
          send(self(), {:prepare_catalog, name})
          {:reply, :accepted, state}
        else
          {:reply, :stale, state}
        end

      _ ->
        {:reply, :stale, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       run_id: state.run_id,
       plugin_id: state.installation.plugin_id,
       release_id: state.installation.release_id,
       artifact_digest: state.installation.artifact_digest,
       skills: skills(state),
       calls: state.calls,
       components:
         Map.new(state.components, fn {name, component} ->
           {name, Map.take(component, [:status, :tools])}
         end),
       diagnostics: state.diagnostics
     }, state}
  end

  def handle_call(:cleanup_status, _from, state), do: {:reply, {:ok, report(state)}, state}

  def handle_call({:close, cleanup, timeout}, from, state) do
    state =
      if state.close_id, do: state, else: begin_close(state, cleanup || state.cleanup_timeout)

    if state.phase == :closed do
      {:reply, {:ok, report(state)}, state}
    else
      waiter = make_ref()

      timer =
        if timeout == :infinity,
          do: nil,
          else: Process.send_after(self(), {:observation_timeout, waiter}, timeout)

      {:noreply, %{state | close_waiters: Map.put(state.close_waiters, waiter, {from, timer})}}
    end
  end

  def handle_call(:stop_confirmed, _from, state) do
    if report(state).outcome == :confirmed,
      do: {:stop, :normal, :ok, state},
      else:
        {:reply, {:error, Error.new(:unknown_outcome, "plugin cleanup is unconfirmed")}, state}
  end

  def handle_call({:catalog, run_id}, _from, %{run_id: run_id, phase: :active} = state),
    do: {:reply, admit(state.tools, run_id), state}

  def handle_call({:skill, run_id, path}, _from, %{run_id: run_id} = state) do
    found = Enum.find(skills(state), &(&1.path == path))
    {:reply, if(found, do: {:ok, found}, else: {:error, :not_found}), state}
  end

  def handle_call({:resource, run_id, path}, _from, %{run_id: run_id} = state),
    do: {:reply, Map.fetch(state.package.files, path), state}

  def handle_call({:call, run_id, name, args}, from, %{run_id: run_id, phase: :active} = state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} ->
        connection = Map.fetch!(state.connections, tool.server)

        call_id = id("call")

        state = %{
          state
          | calls:
              Map.put(state.calls, call_id, %{
                id: call_id,
                tool_name: name,
                server: tool.server,
                outcome: :pending
              })
        }

        {:noreply,
         start_job(state, {:call, call_id, from}, now() + state.timeout, fn ->
           state.adapter.call(connection, tool.name, args, state.timeout)
         end)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:catalog, run_id}, _from, %{run_id: run_id} = state),
    do:
      {:reply, {:error, Error.new(:resource_conflict, "plugin session admission is closed")},
       state}

  def handle_call({:call, run_id, _, _}, _from, %{run_id: run_id} = state),
    do:
      {:reply, {:error, Error.new(:resource_conflict, "plugin session admission is closed")},
       state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, Error.new(:forbidden, "plugin session belongs to another run")}, state}

  @impl true
  def handle_info({:prepare_catalog, name}, state) do
    if state.phase == :active and state.components[name].status == :catalog do
      connection = state.connections[name]

      {:noreply,
       start_job(state, {:catalog, name}, state.activation_deadline, fn ->
         with {:ok, tools} when is_list(tools) <-
                state.adapter.tools(connection, max(1, state.activation_deadline - now())),
              entries = Map.new(tools, &tool_entry(state, name, &1)),
              true <- map_size(entries) == length(tools),
              {:ok, admitted} <- admit(entries, state.run_id) do
           {:ok, Map.take(entries, admitted.accepted)}
         else
           {:error, error} -> {:error, error}
           _ -> {:error, Error.new(:validation, "invalid plugin tool catalog")}
         end
       end)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        cancel_timer(job.timer)
        {:noreply, state |> Map.put(:jobs, jobs) |> settle(job.role, result) |> progress()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        case Map.pop(state.monitors, ref) do
          {nil, _} ->
            {:noreply, state}

          {name, monitors} ->
            state = %{state | monitors: monitors}

            if state.components[name].cleanup_started do
              {:noreply, state}
            else
              {:noreply,
               unavailable(
                 state,
                 name,
                 Error.new(:unknown_outcome, "plugin connection process exited")
               )}
            end
        end

      {job, jobs} ->
        cancel_timer(job.timer)
        error = Error.new(:unknown_outcome, "plugin worker exited without an execution receipt")

        {:noreply,
         state |> Map.put(:jobs, jobs) |> settle(job.role, {:lost, error}) |> progress()}
    end
  end

  def handle_info({:job_timeout, ref}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        Task.shutdown(job.task, :brutal_kill)

        error =
          Error.new(
            :unknown_outcome,
            "plugin worker deadline expired without an execution receipt"
          )

        {:noreply,
         state |> Map.put(:jobs, jobs) |> settle(job.role, {:lost, error}) |> progress()}
    end
  end

  def handle_info({:close_timeout, close_id}, %{close_id: close_id} = state) do
    state =
      Enum.reduce(state.jobs, state, fn {ref, job}, acc ->
        case job.role do
          {:cleanup, _} ->
            Task.shutdown(job.task, :brutal_kill)
            cancel_timer(job.timer)

            acc
            |> Map.update!(:jobs, &Map.delete(&1, ref))
            |> settle(
              job.role,
              {:lost, Error.new(:unknown_outcome, "plugin cleanup deadline expired")}
            )

          _ ->
            acc
        end
      end)

    {:noreply, progress(state)}
  end

  def handle_info({:observation_timeout, waiter}, state) do
    case Map.pop(state.close_waiters, waiter) do
      {nil, _} ->
        {:noreply, state}

      {{from, _}, waiters} ->
        GenServer.reply(
          from,
          {:error,
           Error.new(:timeout, "plugin close observation timed out",
             details: %{run_id: state.run_id, close_id: state.close_id, outcome: :pending}
           )}
        )

        {:noreply, %{state | close_waiters: waiters}}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :state, %{cleanup: report(status.state)})

  @impl true
  def terminate(_reason, state) do
    # Termination has no observed receipt. Never replay an earlier cleanup attempt.
    Enum.each(state.connections, fn {name, connection} ->
      if not state.components[name].cleanup_started do
        Task.Supervisor.start_child(state.supervisor, fn ->
          safely(fn -> state.adapter.stop(connection) end)
        end)
      end
    end)

    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor, :shutdown, 100)
  end

  defp start_job(state, role, deadline, function) do
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> safely(function) end)
    timer = Process.send_after(self(), {:job_timeout, task.ref}, max(0, deadline - now()))
    %{state | jobs: Map.put(state.jobs, task.ref, %{role: role, task: task, timer: timer})}
  end

  defp settle(state, {:start, name}, {:not_allocated, reason}) do
    state = unavailable(state, name, reason)
    put_component(state, name, %{allocation: :none, outcome: :confirmed})
  end

  defp settle(
         %{adapter: MCP} = state,
         {:start, name},
         {:error, %Error{details: %{allocation: :not_started}} = error}
       ) do
    state
    |> unavailable(name, error)
    |> put_component(name, %{allocation: :none, outcome: :confirmed})
  end

  defp settle(state, {:start, name}, result) do
    unavailable(state, name, result)
    |> put_component(name, %{outcome: :uncertain, allocation: :unknown})
  end

  defp settle(state, {:owner, _name}, :owner_retired), do: state

  defp settle(state, {:owner, name}, result) do
    if state.components[name].cleanup_started,
      do: state,
      else: unavailable(state, name, result) |> put_component(name, %{outcome: :uncertain})
  end

  defp settle(state, {:catalog, name}, {:ok, entries}) do
    if state.phase == :active and state.components[name].status == :catalog and
         Enum.all?(Map.keys(entries), &(not Map.has_key?(state.tools, &1))) do
      %{
        put_component(state, name, %{status: :ready, tools: map_size(entries)})
        | tools: Map.merge(state.tools, entries)
      }
    else
      state
      |> unavailable(name, Error.new(:validation, "invalid plugin tool catalog"))
      |> cleanup_once(name)
    end
  end

  defp settle(state, {:catalog, name}, error),
    do: state |> unavailable(name, error) |> cleanup_once(name)

  defp settle(state, {:call, call_id, from}, result) do
    result =
      case result do
        {:lost, error} -> {:error, error}
        {:ok, _} -> result
        {:error, _} -> result
        _ -> {:error, Error.new(:malformed_result, "invalid plugin tool result")}
      end

    GenServer.reply(from, result)
    outcome = if match?({:ok, _}, result), do: :completed, else: :uncertain

    %{
      state
      | calls:
          Map.update!(
            state.calls,
            call_id,
            &Map.merge(&1, %{outcome: outcome, result: diagnostic(result, state)})
          )
    }
  end

  defp settle(state, {:cleanup, name}, result) do
    outcome =
      cond do
        result in [:ok, :done, {:ok, :confirmed}, {:ok, :released}, {:ok, :done}] ->
          :confirmed

        state.adapter == MCP and
            MCP.confirmed_close?(result, state.components[name].activation_id) ->
          :confirmed

        match?({:error, _}, result) ->
          :failed

        true ->
          :uncertain
      end

    state = put_component(state, name, %{outcome: outcome, cleanup: diagnostic(result, state)})

    if outcome == :confirmed do
      ref = state.components[name].owner_ref

      if ref && state.jobs[ref],
        do:
          send(
            state.jobs[ref].task.pid,
            {:retire_activation, state.components[name].activation_id}
          )
    end

    state
  end

  defp begin_close(state, timeout) do
    close_id = id("close")
    deadline = now() + timeout
    timer = Process.send_after(self(), {:close_timeout, close_id}, timeout)

    state = %{
      state
      | phase: :closing,
        close_id: close_id,
        close_deadline: deadline,
        close_timer: timer,
        tools: %{}
    }

    state =
      Enum.reduce(state.jobs, state, fn {ref, job}, acc ->
        case job.role do
          {:call, _, _} ->
            Task.shutdown(job.task, :brutal_kill)
            cancel_timer(job.timer)

            acc
            |> Map.update!(:jobs, &Map.delete(&1, ref))
            |> settle(
              job.role,
              {:lost,
               Error.new(:unknown_outcome, "plugin close interrupted an admitted operation")}
            )

          {kind, _} when kind in [:start, :catalog] ->
            Task.shutdown(job.task, :brutal_kill)
            cancel_timer(job.timer)

            acc
            |> Map.update!(:jobs, &Map.delete(&1, ref))
            |> settle(
              job.role,
              {:lost,
               Error.new(:unknown_outcome, "plugin close interrupted an admitted operation")}
            )

          _ ->
            acc
        end
      end)

    state = Enum.reduce(Map.keys(state.connections), state, &cleanup_once(&2, &1))
    progress(state)
  end

  defp cleanup_once(state, name) do
    component = state.components[name]

    if component.cleanup_started or not Map.has_key?(state.connections, name) do
      state
    else
      deadline = state.close_deadline || now() + state.cleanup_timeout
      cleanup_id = state.close_id || id("close")

      state =
        put_component(state, name, %{
          cleanup_started: true,
          cleanup_id: cleanup_id,
          outcome: :pending
        })

      connection = state.connections[name]

      start_job(state, {:cleanup, name}, deadline, fn ->
        remaining = max(0, deadline - now())

        if remaining == 0 do
          {:lost, Error.new(:unknown_outcome, "plugin cleanup budget exhausted")}
        else
          if function_exported?(state.adapter, :close, 2),
            do:
              state.adapter.close(connection,
                timeout: remaining,
                close_id: cleanup_id,
                activation_id: component.activation_id
              ),
            else: state.adapter.stop(connection)
        end
      end)
    end
  end

  defp progress(state) do
    state = ready(state)
    pending = Enum.any?(state.components, fn {_, component} -> component.outcome == :pending end)

    if state.phase == :closing and not pending do
      cancel_timer(state.close_timer)
      state = %{state | phase: :closed, close_timer: nil}

      Enum.each(state.close_waiters, fn {_, {from, timer}} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, report(state)})
      end)

      %{state | close_waiters: %{}}
    else
      state
    end
  end

  defp ready(state) do
    pending =
      Enum.any?(state.components, fn {_, component} ->
        component.status in [:starting, :catalog] or
          (component.status == :unavailable and component.outcome == :pending)
      end)

    if not pending or state.phase != :active do
      Enum.each(state.ready_waiters, &GenServer.reply(&1, :ready))
      %{state | ready_waiters: []}
    else
      state
    end
  end

  defp unavailable(state, name, reason) do
    component = state.components[name]

    diagnostic = %{
      severity: :error,
      code: :mcp_unavailable,
      path: "mcp.json/" <> name,
      message: "MCP server could not be activated; other components remain available"
    }

    %{
      state
      | components:
          Map.put(state.components, name, %{
            component
            | status: :unavailable,
              activation_error: component.activation_error || diagnostic(reason, state)
          }),
        tools: Map.reject(state.tools, fn {_, tool} -> tool.server == name end),
        diagnostics: state.diagnostics ++ [diagnostic]
    }
  end

  defp put_component(state, name, updates),
    do: %{state | components: Map.update!(state.components, name, &Map.merge(&1, updates))}

  defp monitor_connection(state, name, connection) when is_map(connection) do
    monitors =
      Enum.reduce([:supervisor, :client, :transport], state.monitors, fn key, monitors ->
        pid =
          try do
            GenServer.whereis(Map.get(connection, key))
          rescue
            _ -> nil
          end

        if is_pid(pid), do: Map.put(monitors, Process.monitor(pid), name), else: monitors
      end)

    %{state | monitors: monitors}
  end

  defp monitor_connection(state, _, _), do: state

  defp report(state) do
    %{
      close_id: state.close_id,
      run_id: state.run_id,
      plugin_id: state.installation.plugin_id,
      release_id: state.installation.release_id,
      artifact_digest: state.installation.artifact_digest,
      phase: state.phase,
      outcome:
        if(state.phase == :closed,
          do:
            if(
              Enum.all?(state.components, fn {_, component} -> component.outcome == :confirmed end),
              do: :confirmed,
              else: :unconfirmed
            ),
          else: :pending
        ),
      components:
        Map.new(state.components, fn {name, component} ->
          {name, Map.take(component, [:activation_id, :outcome, :activation_error, :cleanup])}
        end)
    }
  end

  defp skills(state) do
    Enum.map(state.package.skills, fn skill ->
      Map.merge(skill, %{
        plugin_id: state.installation.plugin_id,
        release_id: state.installation.release_id,
        plugin_root: state.root,
        data_dir: state.data_dir
      })
    end)
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, Error.new(:execution_failure, "plugin adapter raised")}
  catch
    _, _ -> {:error, Error.new(:execution_failure, "plugin adapter exited")}
  end

  defp diagnostic(value, state) do
    if :erlang.external_size(value) <= 65_536,
      do: public_diagnostic(value, state.redactions, 0),
      else: %{class: :unknown_outcome, message: "plugin diagnostic exceeded 64 KiB"}
  end

  defp public_diagnostic(_, _, depth) when depth > 12, do: "[bounded]"

  defp public_diagnostic(%Error{} = value, secrets, depth),
    do: public_diagnostic(Map.take(value, [:class, :message, :details]), secrets, depth + 1)

  defp public_diagnostic(%Backplane.McpProtocol.MCP.Error{} = value, secrets, depth),
    do: public_diagnostic(Map.take(value, [:code, :reason, :message, :data]), secrets, depth + 1)

  defp public_diagnostic(%_{}, _, _), do: "[unsupported]"

  defp public_diagnostic(value, secrets, depth) when is_map(value) do
    value
    |> Enum.take(64)
    |> Map.new(fn {key, nested} ->
      key = if is_atom(key) or is_binary(key), do: key, else: "unsupported"

      sensitive =
        Regex.match?(
          ~r/token|credential|authorization|headers|environment|^env$|password|secret/i,
          to_string(key)
        )

      {key, if(sensitive, do: "[redacted]", else: public_diagnostic(nested, secrets, depth + 1))}
    end)
  end

  defp public_diagnostic(value, secrets, depth) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.take(8)
      |> Enum.map(&public_diagnostic(&1, secrets, depth + 1))
      |> List.to_tuple()

  defp public_diagnostic(value, secrets, depth) when is_list(value),
    do: value |> Enum.take(64) |> Enum.map(&public_diagnostic(&1, secrets, depth + 1))

  defp public_diagnostic(value, secrets, _) when is_binary(value) do
    if String.valid?(value),
      do:
        Enum.reduce(secrets, String.slice(value, 0, 1024), &String.replace(&2, &1, "[redacted]")),
      else: "[invalid UTF-8]"
  end

  defp public_diagnostic(value, _, _) when is_reference(value), do: inspect(value)
  defp public_diagnostic(value, _, _) when is_atom(value) or is_number(value), do: value
  defp public_diagnostic(_, _, _), do: "[unsupported]"
  defp strings(value) when is_map(value), do: value |> Map.values() |> strings()
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1) |> Enum.uniq()
  defp strings(value) when is_binary(value) and byte_size(value) > 0, do: [value]
  defp strings(_), do: []
  defp finite_timeout?(value), do: is_integer(value) and value in 1..3_600_000
  defp observation_timeout?(:infinity), do: true
  defp observation_timeout?(value), do: is_integer(value) and value in 0..3_600_000
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp now, do: System.monotonic_time(:millisecond)

  defp id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp admit(entries, run_id) do
    descriptors = entries |> Map.values() |> Enum.map(& &1.descriptor)

    authority = %{
      caller: "plugin-host",
      run_id: run_id,
      grants: Enum.map(descriptors, & &1.tool_name),
      tool_revisions: Map.new(descriptors, &{&1.tool_name, 1})
    }

    ToolCatalog.admit_batch(descriptors, authority: authority, run_id: run_id, mode: :quarantine)
  end

  defp tool_entry(state, server, %{"name" => tool_name} = tool)
       when is_binary(tool_name) and tool_name != "" do
    prefix =
      :crypto.hash(:sha256, state.installation.plugin_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    name = "plugin_" <> prefix <> "_" <> server <> "::" <> tool["name"]
    annotations = Map.get(tool, "annotations", %{})

    descriptor = %{
      tool_name: name,
      tool_revision: 1,
      description: Map.get(tool, "description", ""),
      schema: Map.get(tool, "inputSchema", %{"type" => "object", "properties" => %{}}),
      safety: %{
        read_only: annotations["readOnlyHint"] == true,
        retry_safe: annotations["idempotentHint"] == true,
        parallel_safe: false
      },
      backend: Backend,
      backend_context: %{session: state.session}
    }

    {name, %{server: server, name: tool["name"], descriptor: descriptor}}
  end

  # The specification reserves exactly these two placeholders. Other strings
  # stay literal; credentials are separately bound by the host per server.
  defp expand_config(%{"type" => "stdio"} = config, env) do
    Enum.reduce_while(["args", "env", "cwd"], {:ok, config}, fn field, {:ok, acc} ->
      if Map.has_key?(config, field) do
        case expand(config[field], env) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp expand_config(config, _env), do: {:ok, config}

  defp expand(value, env) when is_binary(value) do
    {:ok,
     Regex.replace(~r/\$\{(PLUGIN_ROOT|PLUGIN_DATA)\}/, value, fn _, key ->
       Map.fetch!(env, key)
     end)}
  end

  defp expand(value, env) when is_map(value), do: expand_pairs(value, env, %{})

  defp expand(value, env) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, items} ->
      case expand(item, env) do
        {:ok, next} -> {:cont, {:ok, items ++ [next]}}
        error -> {:halt, error}
      end
    end)
  end

  defp expand(value, _env), do: {:ok, value}

  defp expand_pairs(value, env, acc) do
    Enum.reduce_while(value, {:ok, acc}, fn {key, item}, {:ok, result} ->
      case expand(item, env) do
        {:ok, expanded} -> {:cont, {:ok, Map.put(result, key, expanded)}}
        error -> {:halt, error}
      end
    end)
  end

  defp bind(config, bindings) do
    Enum.reduce(["env", "headers"], config, fn field, acc ->
      case Map.get(bindings, field) do
        nil ->
          acc

        values when is_map(values) ->
          existing = Map.get(acc, field, %{})

          {existing, values} =
            if field == "headers" do
              normalize = fn map ->
                Map.new(map, fn {key, value} -> {String.downcase(key), value} end)
              end

              {normalize.(existing), normalize.(values)}
            else
              {existing, values}
            end

          Map.put(acc, field, Map.merge(existing, values))
      end
    end)
  end

  defp verify_installation(root, %{content_digest: digest}) when is_binary(digest) do
    alias Backplane.PluginProtocol.Archive

    with {:ok, snapshot} <- Archive.read_directory_with_metadata(root),
         {:ok, bytes} <- Archive.pack(snapshot.files, modes: snapshot.modes),
         true <- Archive.digest(bytes) == digest do
      :ok
    else
      _ -> {:error, :installed_content_changed}
    end
  end

  defp verify_installation(_root, _installation), do: :ok
end
