defmodule Backplane.AgentRuntime.Conversation do
  use GenServer

  alias Backplane.AgentRuntime.{
    Budget,
    Error,
    Execution,
    Goal,
    GoalBridge,
    HostFeedback,
    Usage,
    InputSchema,
    Policy,
    ProviderOutput,
    ToolCatalog,
    ToolEffects,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}

  alias Backplane.AgentRuntime.Kernel, as: RunKernel

  @moduledoc """
  Single authoritative owner of a bounded embedded conversation.

  Drives lazy provider streams and sequential authorized tools without a second
  ExecutionController. All effect intents use Execution.commit/5. Queued inputs,
  messages, interaction state and turn outcomes use kernel checkpoints before
  acknowledgement. Incremental events are transient; terminal events follow
  commit. Subscribers receive `{:agent_runtime, run_id, event}`.

  One root run can contain a prompt and queued follow-up turns. It shares one
  finite work budget and deadline policy. Hosts can explicitly disable the root
  deadline with `run_timeout: :infinity`; effect, commit and cleanup limits remain
  finite. Once settled, the host starts a new run with its canonical messages.
  Host sessions and Protocol V1 remain outside this process. `:run` restores a
  committed record for inspection only: any
  nonterminal restored run enters recovery_required and dispatches nothing.
  The host must reconcile uncertain effects and fence the previous incarnation
  before admitting replacement work. See PERSISTENCE.md and EMBEDDING.md.
  """

  def start_link(opts) do
    with {:ok, feedback} <- HostFeedback.history(opts),
         opts = Keyword.put(opts, :host_feedback, feedback),
         :ok <- ProviderOutput.validate_options(opts),
         :ok <- validate_session_options(opts),
         :ok <- GoalBridge.validate_options(opts),
         :ok <- validate_inherited_deadline(opts),
         {:ok, opts} <- admit_initial_catalog(opts),
         {:ok, _} <- Execution.validate_limits(opts),
         {:ok, _} <- Budget.new(%{work: Keyword.get(opts, :work, 100)}) do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    end
  end

  defp validate_inherited_deadline(opts) do
    case Keyword.get(opts, :inherited_deadline) do
      nil -> :ok
      value when is_integer(value) -> :ok
      _ -> {:error, Error.new(:validation, "inherited deadline must be an absolute timestamp")}
    end
  end

  defp initial_deadline(opts, timeout) do
    configured = if timeout == :infinity, do: :infinity, else: now() + timeout

    case {Keyword.get(opts, :inherited_deadline), configured} do
      {deadline, :infinity} when is_integer(deadline) -> deadline
      {deadline, configured} when is_integer(deadline) -> min(deadline, configured)
      _ -> configured
    end
  end

  defp validate_session_options(opts) do
    if Keyword.has_key?(opts, :run) and Keyword.has_key?(opts, :session_binding),
      do: {:error, Error.new(:forbidden, "restored runs cannot attach a session binding")},
      else: :ok
  end

  defp admit_initial_catalog(opts) do
    mode = Keyword.get(opts, :schema_admission, Keyword.get(opts, :admission_mode))

    cond do
      is_nil(mode) ->
        {:ok, opts}

      mode not in [:strict, :quarantine] ->
        {:error, Error.new(:validation, "admission mode must be :strict or :quarantine")}

      true ->
        registry = Keyword.get(opts, :registry, %ToolRegistry{})
        authority = Keyword.get(opts, :authority, %{})

        case ToolCatalog.admit_batch(
               %{
                 registry: registry,
                 authority: authority,
                 tools: Keyword.get(opts, :tools),
                 run_id: Keyword.get(opts, :run_id)
               },
               mode: mode
             ) do
          {:ok, bundle} ->
            {:ok,
             opts
             |> Keyword.put(:registry, bundle.registry)
             |> Keyword.put(:tools, bundle.tools)
             |> Keyword.put(:authority, bundle.authority)}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  def child_spec(opts),
    do: %{
      id: Keyword.fetch!(opts, :run_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  def prompt(pid, content), do: GenServer.call(pid, {:input, :prompt, content}, :infinity)
  def steer(pid, content), do: GenServer.call(pid, {:input, :steering, content}, :infinity)
  def follow_up(pid, content), do: GenServer.call(pid, {:input, :follow_up, content}, :infinity)

  def queue_only(pid, content, communication, expected),
    do: GenServer.call(pid, {:queue_only, content, communication, expected}, :infinity)

  def public_interaction(value), do: HostFeedback.public(value)

  def resolve(pid, id, value), do: GenServer.call(pid, {:resolve, id, value}, :infinity)

  def stage_catalog(pid, update),
    do: GenServer.call(pid, {:stage_catalog, nil, update}, :infinity)

  def cancel(pid), do: GenServer.call(pid, :cancel)
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    {:ok, sup} = Task.Supervisor.start_link()
    {:ok, limits} = Execution.validate_limits(opts)

    {:ok, budget} =
      Budget.new(%{
        root_run_id: Keyword.fetch!(opts, :run_id),
        work: Keyword.get(opts, :work, 100)
      })

    conversation = %{
      messages: Keyword.get(opts, :messages, []),
      host_feedback: Keyword.get(opts, :host_feedback, []),
      steering: [],
      follow_up: [],
      mailbox: Keyword.get(opts, :mailbox, []),
      turn_id: nil,
      turns: [],
      pending_interaction: nil,
      queue_status: :active,
      usage: []
    }

    run =
      Keyword.get_lazy(opts, :run, fn ->
        %{
          run_id: Keyword.fetch!(opts, :run_id),
          incarnation: Keyword.get(opts, :incarnation, 1),
          expected_revision: 0,
          state: :queued,
          admitted: false,
          context: %{conversation: conversation},
          children: [],
          deadline: initial_deadline(opts, limits.run),
          execution_budget: budget
        }
      end)

    restored? = Keyword.has_key?(opts, :run)

    phase =
      if restored?,
        do: if(RunKernel.terminal?(run.state), do: :terminal, else: :recovery_required),
        else: :idle

    {timer, generation} = if restored?, do: {nil, nil}, else: run_timer(run)

    catalog = ToolCatalog.initial(opts)

    state = %{
      opts: opts,
      run: run,
      conversation:
        Map.put_new(get_in(run, [:context, :conversation]) || conversation, :host_feedback, []),
      phase: phase,
      supervisor: sup,
      limits: limits,
      commit: nil,
      commit_queue: :queue.new(),
      effect: nil,
      preparation: nil,
      tool_admission_deadline: nil,
      paused_admission_remaining: nil,
      nested: nil,
      nested_admission: nil,
      jobs: :queue.new(),
      interaction: nil,
      stopping: nil,
      cleanup_due: nil,
      timer: timer,
      timer_generation: generation,
      effect_live_deadline: nil,
      paused_run_remaining: nil,
      paused_effect_remaining: nil,
      paused_preparation_remaining: nil,
      paused_nested_remaining: nil,
      callers: [],
      admission: nil,
      last_error: nil,
      provider_output: ProviderOutput.new(),
      catalog: catalog,
      pending_catalog: nil,
      catalog_receipts: [],
      new_context_requested: false,
      resource_registries: resource_registries(catalog.registry),
      goal_binding: Keyword.get(opts, :goal_binding),
      goal_delivery: nil,
      provider_progress_from: nil,
      resource_cleanup: :not_requested,
      input_runtimes: input_runtimes(opts, catalog.registry),
      input_binding_pending: %{}
    }

    case Keyword.get(opts, :session_binding) do
      nil ->
        {:ok, bind_inputs(state)}

      binding ->
        if binding.run_id == run.run_id and binding.run_incarnation == run.incarnation do
          case Session.attach(binding, catalog) do
            :ok -> {:ok, bind_inputs(state)}
            {:error, error} -> {:stop, error}
          end
        else
          {:stop, Error.new(:forbidden, "conversation identity does not match session binding")}
        end
    end
  end

  @impl true
  def handle_call({:queue_only, content, communication, expected}, from, s) do
    cond do
      expected != input_identity(s) ->
        {:reply, {:error, Error.new(:forbidden, "stale mailbox destination")}, s}

      s.phase in [:terminal, :storage_failed, :recovery_required, :cancelling] ->
        {:reply,
         {:error, Error.new(:unknown_outcome, "mailbox destination is not accepting input")}, s}

      not is_binary(content) or content == "" ->
        {:reply, {:error, Error.new(:validation, "mailbox message must be text")}, s}

      true ->
        message = %{
          role: :user,
          content: content,
          id: communication.result_id,
          collaboration: communication
        }

        {:noreply, enqueue(%{s | callers: [from | s.callers]}, {:mailbox, message, from})}
    end
  end

  def handle_call(:status, _from, s),
    do:
      {:reply,
       %{
         phase: s.phase,
         run: s.run,
         messages: s.conversation.messages,
         conversation: s.conversation,
         error: s.last_error,
         catalog_revision: s.catalog.revision,
         catalog_publication: catalog_publication(s.catalog, :published),
         pending_catalog_publication:
           catalog_publication(s.pending_catalog && s.pending_catalog.catalog, :staged),
         resource_cleanup: s.resource_cleanup
       }, s}

  def handle_call({:stage_catalog, token, update}, _from, s) do
    case stage_catalog(s, token, update) do
      {:ok, receipt, next} -> {:reply, {:ok, receipt}, next}
      {:error, %Error{} = error} -> {:reply, {:error, error}, s}
    end
  end

  def handle_call(:cancel, _from, %{phase: phase} = s)
      when phase in [:terminal, :recovery_required, :storage_failed],
      do: {:reply, {:error, Error.new(:resource_conflict, "run is not active")}, s}

  def handle_call(:cancel, from, s) do
    # Acknowledge acceptance before bounded resource cleanup. This server cannot
    # process another effect callback until stop/2 has fenced and cleared it.
    GenServer.reply(from, :ok)
    {:noreply, stop(s, :cancelled)}
  end

  def handle_call({:input, mode, content}, from, s) do
    cond do
      s.phase in [:terminal, :recovery_required, :storage_failed, :cancelling] ->
        {:reply, {:error, Error.new(:resource_conflict, "run is not accepting input")}, s}

      content == [] or content == "" ->
        {:reply, {:error, Error.new(:validation, "prompt must not be empty")}, s}

      not (is_binary(content) or is_list(content)) ->
        {:reply, {:error, Error.new(:validation, "content must be text or content blocks")}, s}

      true ->
        {:noreply, enqueue(%{s | callers: [from | s.callers]}, {:input, mode, content, from})}
    end
  end

  def handle_call({:resolve, _, _}, _from, %{phase: phase} = s)
      when phase in [:terminal, :cancelling, :storage_failed, :recovery_required],
      do: {:reply, {:error, Error.new(:resource_conflict, "run is not accepting resolutions")}, s}

  def handle_call({:resolve, id, value}, from, s),
    do: {:noreply, enqueue(%{s | callers: [from | s.callers]}, {:resolve, id, value, from})}

  def handle_call({:interact, token, request}, from, s) do
    with true <- current_effect?(s, token) and is_nil(s.interaction),
         true <- is_map(request),
         {:ok, _} <- public_interaction(request) do
      {:noreply, enqueue(s, {:interact, token, request, from})}
    else
      {:error, error} ->
        {:reply, {:error, error}, s}

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "stale or overlapping interaction")}, s}
    end
  end

  def handle_call({:append_feedback, token, payload}, from, s) do
    with {:ok, _invocation, _enclosing} <- feedback_producer(s, token),
         {:ok, payload} <- HostFeedback.payload(payload) do
      {:noreply,
       enqueue(%{s | callers: [from | s.callers]}, {:append_feedback, token, payload, from})}
    else
      {:error, error} -> {:reply, {:error, error}, s}
    end
  end

  def handle_call({:provider_chunk, token, event}, from, s) do
    if current_effect?(s, token) and not is_nil(s.effect) and
         match?({:provider, _, _}, s.effect.role) and
         is_nil(s.provider_progress_from) and valid_provider_event?(event) do
      if cumulative_provider_progress?(s, event) do
        output = ProviderOutput.event(s.provider_output, event)

        case ProviderOutput.check(output, ProviderOutput.limit(s.opts)) do
          {:ok, output} ->
            s = refresh_provider_idle(%{s | provider_output: output})
            checkpoint_provider_progress(s, event, from)

          {:error, error} ->
            {:reply, {:error, error}, s}
        end
      else
        {:reply, {:error, Error.new(:validation, "cumulative provider usage regressed")}, s}
      end
    else
      {:reply, {:error, Error.new(:resource_conflict, "stale provider stream")}, s}
    end
  end

  def handle_call({:chunk, token, event}, _from, s) do
    if current_effect?(s, token) and is_map(event) do
      output = ProviderOutput.event(s.provider_output, event)

      case ProviderOutput.check(output, ProviderOutput.limit(s.opts)) do
        {:ok, output} ->
          if Map.get(event, :type) != :response_completed, do: emit(s, event)
          {:reply, :ok, %{s | provider_output: output}}

        {:error, error} ->
          {:reply, {:error, error}, s}
      end
    else
      {:reply, {:error, Error.new(:resource_conflict, "stale stream")}, s}
    end
  end

  def handle_call({:request_new_context, token}, _from, s) do
    if current_effect?(s, token) do
      {:reply, :ok, %{s | new_context_requested: true}}
    else
      {:reply, {:error, Error.new(:resource_conflict, "stale context-window request")}, s}
    end
  end

  def handle_call({:nested_tool, token, request}, from, s) do
    case prepare_nested_tool(s, token, request) do
      {:ok, invocation, descriptor, catalog} ->
        {:noreply, prepare_tool(s, invocation, descriptor, catalog, {:nested, from})}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, s}
    end
  end

  defp invoke_nested_tool(s, invocation, catalog, from) do
    s = %{s | tool_admission_deadline: nil}
    resource_owner_pid = self()
    nested_token = make_ref()

    opts = [
      registry: catalog.registry,
      authority: catalog.authority,
      ephemeral_tool_authority: true
    ]

    next = fn next_state, prepared ->
      task =
        Task.Supervisor.async_nolink(next_state.supervisor, fn ->
          prepared = %{
            prepared
            | operation: Map.put(prepared.operation, :effective_authority, catalog.authority),
              host_context:
                Map.merge(
                  prepared.host_context,
                  trusted_effect_context(
                    next_state,
                    nested_token,
                    catalog,
                    resource_owner_pid,
                    invocation,
                    outer_invocation(invocation, next_state)
                  )
                )
                |> Map.merge(goal_tool_context(next_state))
          }

          Execution.dispatch(
            prepared,
            Keyword.merge(next_state.opts,
              registry: catalog.registry,
              authority: catalog.authority
            )
          )
        end)

      generation = make_ref()
      timeout = effect_timeout(next_state, next_state.limits.effect)
      timer = Process.send_after(self(), {:nested_timeout, task.ref, generation}, timeout)

      %{
        next_state
        | nested_admission: nil,
          nested: %{
            task: task,
            timer: timer,
            timer_generation: generation,
            live_deadline: System.monotonic_time(:millisecond) + timeout,
            from: from,
            token: nested_token,
            invocation: invocation,
            catalog: catalog
          }
      }
    end

    s = %{s | nested_admission: invocation}
    commit(s, {:tool_invoked, now(), invocation}, %{}, opts, next)
  end

  @impl true
  def handle_info({:codex_input_bound, runtime, identity, {:ok, entries}}, s) do
    case s.input_binding_pending[runtime] do
      %{identity: ^identity, timer: timer} ->
        Process.cancel_timer(timer)
        conversation = Map.update(s.conversation, :mailbox, entries, &(&1 ++ entries))

        {:noreply,
         drive(%{
           s
           | conversation: conversation,
             input_binding_pending: Map.delete(s.input_binding_pending, runtime)
         })}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:codex_input_bound, runtime, identity, {:error, error}}, s),
    do: {:noreply, fail_input_binding(s, runtime, identity, error)}

  def handle_info({:codex_input_binding_timeout, runtime, identity}, s),
    do:
      {:noreply,
       fail_input_binding(
         s,
         runtime,
         identity,
         Error.new(:unknown_outcome, "collaboration input binding was not acknowledged")
       )}

  def handle_info({:codex_session_close, token}, s) do
    case Keyword.get(s.opts, :session_binding) do
      %{token: ^token} -> {:noreply, stop(s, :cancelled)}
      _ -> {:noreply, s}
    end
  end

  def handle_info(
        {ref, result},
        %{goal_delivery: %{task: %{ref: ref}, kind: :unbind} = entry} = s
      ) do
    clear_task(entry)
    s = %{s | goal_delivery: nil}

    case result do
      {:ok, :unbound} ->
        {:noreply, entry.next.(%{s | goal_binding: nil})}

      {:error, error} ->
        {:noreply, storage_failed(s, error)}

      _ ->
        {:noreply,
         storage_failed(
           s,
           Error.new(:malformed_result, "invalid goal revocation acknowledgement")
         )}
    end
  end

  def handle_info({ref, result}, %{goal_delivery: %{task: %{ref: ref}} = entry} = s) do
    clear_task(entry)
    s = %{s | goal_delivery: nil}
    {:noreply, drive(process(s, {:effect_result, {:goal_delivery, entry.next}, result}))}
  end

  def handle_info(
        {:goal_timeout, ref, generation},
        %{goal_delivery: %{task: %{ref: ref}, timer_generation: generation} = entry} = s
      ) do
    kill_task(entry)

    {:noreply,
     storage_failed(%{s | goal_delivery: nil}, Error.new(:timeout, "goal delivery timed out"))}
  end

  def handle_info({ref, result}, %{preparation: %{task: %{ref: ref}} = entry} = s) do
    clear_task(entry)

    {:noreply,
     enqueue(
       %{s | preparation: %{entry | task: nil, timer: nil, timer_generation: nil}},
       {:prepared_tool, entry, result}
     )}
  end

  def handle_info({ref, result}, %{nested: %{task: %{ref: ref}} = nested} = s) do
    clear_task(nested)
    {:noreply, complete_nested(s, normalize_nested_result(result))}
  end

  def handle_info({ref, result}, %{commit: %{task: %{ref: ref}} = entry} = s) do
    clear_task(entry)
    s = %{s | commit: nil}

    case result do
      {:ok, _receipt, prepared} ->
        s = %{
          s
          | run: prepared.run,
            conversation: get_in(prepared.run, [:context, :conversation]) || s.conversation
        }

        s =
          cond do
            RunKernel.terminal?(prepared.run.state) ->
              entry.next.(%{invalidate_run_timer(s) | stopping: nil}, prepared)

            s.stopping ->
              advance_stop(s)

            true ->
              entry.next.(s, prepared)
          end

        {:noreply, drive(s)}

      {:error, %Error{class: :timeout, details: %{boundary: :before_store}}} ->
        {:noreply, stop(s, :deadline_exceeded)}

      {:error, error} ->
        {:noreply, storage_failed(s, error)}
    end
  end

  def handle_info({ref, result}, %{effect: %{task: %{ref: ref}} = entry} = s) do
    clear_task(entry)
    s = %{s | effect: nil}

    if s.preparation && s.preparation.outer_token == entry.token do
      # An escaped nested caller cannot outlive the enclosing invocation.
      {:noreply, stop(s, :uncertain)}
    else
      {:noreply, enqueue(s, {:effect_result, entry.role, result})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    error = Error.new(:execution_failure, "worker exited", cause: inspect(reason))

    cond do
      s.goal_delivery && s.goal_delivery.task.ref == ref ->
        {:noreply, storage_failed(%{s | goal_delivery: nil}, error)}

      s.commit && s.commit.task.ref == ref ->
        {:noreply, storage_failed(%{s | commit: nil}, error)}

      s.nested && s.nested.task && s.nested.task.ref == ref ->
        clear_task(s.nested)

        error =
          Error.new(:execution_failure, "nested worker exited before settlement",
            cause: inspect(reason)
          )

        if s.phase == :waiting_interaction do
          {:noreply, stop(%{s | last_error: error}, :uncertain)}
        else
          {:noreply, complete_nested(s, {:error, error})}
        end

      s.preparation && s.preparation.task && s.preparation.task.ref == ref ->
        clear_task(s.preparation)
        entry = s.preparation

        if s.interaction do
          {:noreply, stop(s, :cancelled)}
        else
          {:noreply,
           enqueue(
             %{s | preparation: %{entry | task: nil, timer: nil, timer_generation: nil}},
             {:prepared_tool, entry, {:error, error}}
           )}
        end

      s.effect && s.effect.task.ref == ref ->
        if s.effect.timer, do: Process.cancel_timer(s.effect.timer)
        {:noreply, stop(%{s | effect: nil, last_error: error}, :uncertain)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info({:timeout, ref, generation}, s) when is_reference(generation) do
    cond do
      s.commit && s.commit.task.ref == ref && s.commit.timer_generation == generation ->
        kill_task(s.commit)

        {:noreply,
         storage_failed(
           %{s | commit: nil},
           Error.new(:timeout, "commit acknowledgement timed out")
         )}

      s.preparation && s.preparation.task && s.preparation.task.ref == ref &&
          s.preparation.timer_generation == generation ->
        {:noreply, stop(s, :deadline_exceeded)}

      s.effect && s.effect.task.ref == ref && s.effect.timer_generation == generation ->
        {:noreply, stop(s, :deadline_exceeded)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(
        {:nested_timeout, ref, generation},
        %{nested: %{task: %{ref: ref}, timer_generation: generation} = nested} = s
      )
      when is_reference(generation) do
    kill_task(nested)

    {:noreply,
     complete_nested(s, {:error, Error.new(:timeout, "nested tool execution timed out")})}
  end

  def handle_info(
        {:deadline, run_id, incarnation, generation},
        %{run: %{run_id: run_id, incarnation: incarnation}, timer_generation: generation} = s
      )
      when is_reference(generation) do
    {:noreply, stop(s, :deadline_exceeded)}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    if s.effect, do: kill_task(s.effect)
    if s.preparation, do: kill_task(s.preparation)
    if s.goal_delivery, do: kill_task(s.goal_delivery)
    if s.commit, do: kill_task(s.commit)
    if s.nested && s.nested.task, do: kill_task(s.nested)
    if Process.alive?(s.supervisor), do: Supervisor.stop(s.supervisor)
  end

  defp enqueue(s, job), do: drive(%{s | jobs: :queue.in(job, s.jobs)})
  defp drive(%{commit: commit} = s) when not is_nil(commit), do: s
  defp drive(%{input_binding_pending: pending} = s) when map_size(pending) > 0, do: s
  defp drive(%{goal_delivery: delivery} = s) when not is_nil(delivery), do: s
  defp drive(%{stopping: stopping} = s) when not is_nil(stopping), do: advance_stop(s)

  defp drive(%{commit_queue: queue} = s) do
    case :queue.out(queue) do
      {:empty, _} ->
        drive_jobs(s)

      {{:value, {command, meta, extra, next}}, queue} ->
        s = %{s | commit_queue: queue}
        commit(s, rebase_queued_command(s, command), meta, extra, next)
    end
  end

  defp drive_jobs(s) do
    case :queue.out(s.jobs) do
      {:empty, _} -> s
      {{:value, job}, jobs} -> s |> Map.put(:jobs, jobs) |> process(job) |> drive()
    end
  end

  defp process(%{phase: phase} = s, {:input, _, _, from})
       when phase in [:terminal, :storage_failed, :recovery_required, :cancelling] do
    reply(s, from, {:error, Error.new(:resource_conflict, "run is not accepting input")})
  end

  defp process(s, {:mailbox, message, from}) do
    if s.phase in [:terminal, :storage_failed, :recovery_required, :cancelling] do
      reply(
        s,
        from,
        {:error, Error.new(:unknown_outcome, "mailbox destination is not accepting input")}
      )
    else
      mailbox = Map.get(s.conversation, :mailbox, [])

      conversation =
        Map.put(
          s.conversation,
          :mailbox,
          if(Enum.any?(mailbox, &(&1.id == message.id)), do: mailbox, else: mailbox ++ [message])
        )

      accepted = fn next ->
        input_activity(next, :mailbox)

        reply(
          next,
          from,
          {:ok,
           %{
             message_id: message.id,
             acceptance: if(next.run.state == :queued, do: :process_local, else: :checkpointed)
           }}
        )
      end

      if s.run.state == :queued,
        do: accepted.(%{s | conversation: conversation}),
        else: checkpoint(s, conversation, accepted)
    end
  end

  defp process(s, {:input, mode, content, from}) do
    message = %{role: :user, content: content, id: id("message")}

    if s.phase == :idle do
      mailbox = Map.get(s.conversation, :mailbox, [])
      s = %{s | phase: :starting}

      commit(s, {:admit, now(), %{state: :running, deadline: s.run.deadline}}, %{}, [], fn s, _ ->
        # Pre-admission inbox entries are process-local until the first prompt checkpoint.
        conversation = Map.put(s.conversation, :mailbox, mailbox)

        begin_prompt(
          %{s | admission: {from, message.id}, conversation: conversation},
          message,
          :new
        )
      end)
    else
      mode = if mode == :prompt, do: :follow_up, else: mode
      conversation = Map.update!(s.conversation, mode, &(&1 ++ [message]))

      checkpoint(s, conversation, fn s ->
        if mode == :steering, do: input_activity(s, :steer)
        reply(s, from, {:ok, %{message_id: message.id}})
      end)
    end
  end

  defp process(s, {:append_feedback, token, payload, from}) do
    with {:ok, invocation, enclosing} <- feedback_producer(s, token) do
      correlation = HostFeedback.correlation(invocation, enclosing)
      records = Map.get(s.conversation, :host_feedback, [])

      case Enum.find(records, &(&1["id"] == payload["id"])) do
        nil ->
          store = Keyword.fetch!(s.opts, :store)

          record =
            HostFeedback.record(payload, correlation, s.run.expected_revision + 1, store.mode())

          conversation = Map.put(s.conversation, :host_feedback, records ++ [record])

          checkpoint(s, conversation, fn next ->
            case feedback_producer(next, token) do
              {:ok, _, _} -> reply(next, from, {:ok, HostFeedback.receipt(record)})
              {:error, error} -> reply(next, from, {:error, error})
            end
          end)

        record ->
          if HostFeedback.same?(record, payload, correlation),
            do: reply(s, from, {:ok, HostFeedback.receipt(record)}),
            else:
              reply(
                s,
                from,
                {:error,
                 Error.new(
                   :resource_conflict,
                   "feedback ID already belongs to another payload or invocation"
                 )}
              )
      end
    else
      {:error, error} -> reply(s, from, {:error, error})
    end
  end

  defp process(s, {:interact, token, request, from}) do
    if current_effect?(s, token) and is_nil(s.interaction) do
      interaction = %{id: id("interaction"), request: request}

      s = %{s | interaction: %{id: interaction.id, from: from, token: token}}

      checkpoint(s, %{s.conversation | pending_interaction: interaction}, fn s ->
        if (current_effect?(s, token) and s.interaction) && s.interaction.id == interaction.id do
          emit(s, %{
            type: :interaction_requested,
            interaction_id: interaction.id,
            request: request
          })

          %{pause_deadlines(s) | phase: :waiting_interaction}
        else
          checkpoint(s, %{s.conversation | pending_interaction: nil}, & &1)
        end
      end)
    else
      GenServer.reply(from, {:error, Error.new(:resource_conflict, "stale interaction")})
      s
    end
  end

  defp process(%{phase: phase} = s, {:resolve, _, _, from})
       when phase in [:terminal, :cancelling, :storage_failed, :recovery_required],
       do:
         reply(
           s,
           from,
           {:error, Error.new(:resource_conflict, "run is not accepting resolutions")}
         )

  defp process(s, {:resolve, id, value, from}) do
    case s.interaction do
      %{id: ^id, from: waiter, token: token} ->
        deadline = resume_deadline(s)

        checkpoint(
          s,
          %{s.conversation | pending_interaction: nil},
          fn s ->
            if current_effect?(s, token) and match?(%{id: ^id, token: ^token}, s.interaction) do
              GenServer.reply(waiter, {:ok, value})
              s = reply(s, from, :ok)
              emit(s, %{type: :interaction_resolved, interaction_id: id})
              resume_deadlines(%{s | interaction: nil, phase: :running})
            else
              reply(
                s,
                from,
                {:error, Error.new(:resource_conflict, "interaction is no longer live")}
              )
            end
          end,
          execution_deadline: deadline
        )

      _ ->
        reply(s, from, {:error, Error.new(:not_found, "interaction is not pending")})
    end
  end

  defp process(s, {:effect_result, {:prompt, message, mode}, result}) do
    case result do
      {:ok, message} when is_map(message) ->
        conversation = %{s.conversation | messages: s.conversation.messages ++ [message]}

        conversation =
          if mode == :new, do: %{conversation | turn_id: id("turn")}, else: conversation

        conversation =
          if mode == :new,
            do:
              GoalBridge.queue(s, conversation, [
                {:turn_started,
                 %{mode: goal_mode(s), trigger: Keyword.get(s.opts, :goal_trigger, :user)}}
              ]),
            else: conversation

        checkpoint(s, conversation, fn s ->
          emit(s, %{
            type: :prompt_consumed,
            mode: mode,
            message: message,
            turn_id: conversation.turn_id
          })

          s = acknowledge_admission(s, :ok)

          if mode == :steering do
            input_activity(
              s,
              if(s.conversation.steering == [], do: :steer_consumed, else: :steer)
            )
          end

          deliver_goal(s, &start_provider/1)
        end)

      {:error, error} ->
        s = acknowledge_admission(s, {:error, error})

        if mode == :steering do
          input_activity(s, if(s.conversation.steering == [], do: :steer_consumed, else: :steer))
        end

        emit(s, %{type: :prompt_rejected, message_id: message.id, error: error})

        if mode == :new,
          do: finish_turn(%{s | last_error: error}, :failed),
          else: after_boundary(s, false)

      _ ->
        fail(s, "invalid prompt hook result")
    end
  end

  defp process(s, {:effect_result, {:provider, identity, catalog}, result}) do
    case result do
      {:ok, response} ->
        conversation = %{
          s.conversation
          | messages: s.conversation.messages ++ [response.message],
            usage: s.conversation.usage ++ response.usage
        }

        case goal_provider_usage(s, conversation, response.usage, identity) do
          {:ok, conversation} ->
            conversation =
              GoalBridge.queue(s, conversation, [
                {:item_completed,
                 %{
                   kind: :assistant,
                   text: goal_text(response.message),
                   phase: response.message[:phase],
                   questions: response.message[:questions]
                 }}
              ])

            input =
              Map.merge(identity, %{
                final?: false,
                result: response,
                context: Map.put(s.run.context, :conversation, conversation)
              })

            commit(s, {:provider_completed, now(), input}, %{}, [], fn s, _ ->
              emit(s, response.terminal)
              deliver_goal(s, &begin_tools(&1, response.tools, catalog))
            end)

          {:error, error} ->
            storage_failed(s, error)
        end

      {:error, error} ->
        conversation =
          GoalBridge.queue(s, s.conversation, [
            {:turn_error, %{class: goal_error_class(error), retryable: false}}
          ])

        input =
          Map.merge(identity, %{
            final?: false,
            result: %{error: error},
            context: Map.put(s.run.context, :conversation, conversation)
          })

        commit(s, {:provider_completed, now(), input}, %{}, [], fn s, _ ->
          emit(s, %{type: :response_failed, error: error})
          deliver_goal(s, &finish_turn(%{&1 | last_error: error}, :failed))
        end)
    end
  end

  defp process(s, {:effect_result, {:tool, invocation, rest, catalog}, result}) do
    s = discard_failed_catalog(s, invocation, result)

    if tool_settlement(catalog, invocation, result) == :uncertain do
      stop(%{s | last_error: uncertain_error(result)}, :uncertain)
    else
      normalized = tool_result(result)

      conversation =
        GoalBridge.queue(s, s.conversation, [
          {:tool_finished, goal_tool_payload(invocation, normalized)}
        ])

      input =
        invocation
        |> Map.put(:result, normalized)
        |> Map.put(:context, Map.put(s.run.context, :conversation, conversation))

      commit(s, {:tool_completed, now(), input}, %{}, [], fn s, _ ->
        s = settle_catalog_producer(s, invocation, normalized)
        deliver_goal(s, &append_tool_result(&1, invocation, normalized, rest, catalog))
      end)
    end
  end

  defp process(
         %{preparation: %{token: token}} = s,
         {:prepared_tool, %{token: token} = entry, result}
       ) do
    if s.interaction && s.interaction.token == entry.token do
      stop(s, :cancelled)
    else
      accept_preparation(s, entry, result)
    end
  end

  defp process(s, {:prepared_tool, _entry, _result}), do: s

  defp process(
         s,
         {:effect_result, {:approval, invocation, descriptor, rest, catalog},
          {:ok, {:update_input, input}}}
       ) do
    admit_prepared_tool(s, %{invocation | arguments: input}, descriptor, catalog, {:direct, rest})
  end

  defp process(
         s,
         {:effect_result, {:approval, invocation, descriptor, rest, catalog}, {:ok, decision}}
       ) do
    if decision == :approved do
      approval =
        %{
          approval_id: id("approval"),
          run_id: s.run.run_id,
          tool_name: invocation.tool_name,
          tool_revision: invocation.tool_revision,
          arguments_digest: digest(invocation.arguments),
          current_time: now(),
          expires_at: s.run.deadline
        }
        |> Map.merge(Map.take(invocation, [:collaboration_binding]))

      decision =
        Map.merge(
          Map.take(approval, [
            :approval_id,
            :tool_name,
            :tool_revision,
            :arguments_digest,
            :collaboration_binding
          ]),
          %{decision: :approved, resolver_id: "host"}
        )

      invoke_tool(s, invocation, descriptor, rest, catalog,
        approval: approval,
        approval_decision: decision
      )
    else
      append_tool_result(
        %{s | tool_admission_deadline: nil},
        invocation,
        %{is_error: true, error: "approval denied"},
        rest,
        catalog
      )
    end
  end

  defp process(s, {:effect_result, :stop_hook, result}) do
    case result do
      :stop ->
        finish_turn(s, :completed)

      {:continue, message} when is_map(message) ->
        checkpoint(
          s,
          %{s.conversation | messages: s.conversation.messages ++ [message]},
          &start_provider/1
        )

      {:error, error} ->
        finish_turn(%{s | last_error: error}, :failed)

      _ ->
        fail(s, "invalid stop hook result")
    end
  end

  defp process(s, {:effect_result, {:goal_delivery, next}, {:ok, responses, binding}}) do
    conversation = Map.put(s.conversation, :goal_outbox, [])

    conversation =
      Enum.reduce(responses, conversation, fn response, conversation ->
        case response.steering do
          nil ->
            conversation

          item ->
            Map.update!(
              conversation,
              :steering,
              &(&1 ++ [%{role: :user, content: item.text, source: :goal}])
            )
        end
      end)

    checkpoint(%{s | goal_binding: binding}, conversation, next)
  end

  defp process(s, {:effect_result, {:goal_delivery, _}, {:error, error}}),
    do: storage_failed(s, error)

  defp process(s, {:effect_result, _, _}), do: fail(s, "invalid adapter result")

  defp begin_prompt(s, message, mode) do
    s = if mode == :new, do: %{s | last_error: nil}, else: s

    start_effect(s, {:prompt, message, mode}, fn context ->
      hook(s, :prompt, [message, context], {:ok, message})
    end)
  end

  defp start_provider(s) do
    conversation = HostFeedback.project(s.conversation)

    if conversation != s.conversation do
      checkpoint(s, conversation, &start_provider/1)
    else
      start_provider_with_mailbox(s)
    end
  end

  defp start_provider_with_mailbox(s) do
    case Map.get(s.conversation, :mailbox, []) do
      [] ->
        do_start_provider(s)

      messages ->
        conversation =
          s.conversation
          |> Map.put(:mailbox, [])
          |> Map.update!(:messages, &(&1 ++ messages))

        checkpoint(s, conversation, fn next ->
          input_activity(next, :mailbox_consumed)
          do_start_provider(next)
        end)
    end
  end

  defp do_start_provider(s) do
    catalog = s.catalog
    identity = Map.merge(identity(s), %{step_id: id("step"), attempt_id: id("attempt")})

    request =
      Map.merge(identity, %{
        messages: s.conversation.messages,
        turn_id: s.conversation.turn_id,
        catalog_revision: catalog.revision,
        tools: catalog.tools ++ Keyword.get(s.opts, :hosted_tools, [])
      })

    opts = [adapter: Keyword.fetch!(s.opts, :provider)]

    commit(s, {:provider_started, now(), identity}, %{operation: request}, opts, fn s, _ ->
      start_effect(
        %{s | provider_output: ProviderOutput.new()},
        {:provider, identity, catalog},
        fn context ->
          stream(s, request, context)
        end
      )
    end)
  end

  defp stream(s, request, context) do
    provider = Keyword.fetch!(s.opts, :provider)
    initial = %{tools: [], usage: [], terminal: nil, message: nil}

    result =
      Enum.reduce_while(provider.stream(request, context), {:ok, initial}, fn event, {:ok, acc} ->
        case event do
          %{type: :response_completed, message: %{role: :assistant, content: content} = message}
          when is_binary(content) or is_list(content) ->
            with {:ok, tools} <- terminal_tools(acc.tools, message),
                 :ok <- context.provider_emit.(event) do
              usage = if Map.get(event, :usage), do: acc.usage ++ [event.usage], else: acc.usage

              {:halt,
               {:ok, %{acc | terminal: event, message: message, tools: tools, usage: usage}}}
            else
              {:error, _} = error -> {:halt, error}
            end

          %{type: :response_failed} ->
            {:halt, {:error, Map.get(event, :error, "provider failed")}}

          %{type: type}
          when type in [
                 :response_started,
                 :content_text_delta,
                 :content_thinking_delta,
                 :tool_call_started,
                 :tool_call_arguments_delta,
                 :tool_call_completed,
                 :provider_hosted_event,
                 :usage_updated
               ] ->
            with {:ok, acc} <- collect(acc, event),
                 :ok <- context.provider_emit.(event) do
              {:cont, {:ok, acc}}
            else
              {:error, _} = error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, "unsupported normalized provider event"}}
        end
      end)

    case result do
      {:ok, %{terminal: nil}} ->
        {:error, "provider ended without terminal event"}

      {:ok, response} ->
        {:ok, response}

      error ->
        error
    end
  end

  defp terminal_tools(streamed, message) do
    blocks =
      case Map.get(message, :content) do
        blocks when is_list(blocks) ->
          Enum.filter(blocks, &(is_map(&1) and Map.get(&1, :type) == :tool_call))

        _ ->
          []
      end

    if blocks == [] do
      {:ok, streamed}
    else
      Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, tools} ->
        case collect(%{tools: tools}, %{type: :tool_call_completed, tool_call: block}) do
          {:ok, %{tools: tools}} -> {:cont, {:ok, tools}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp collect(acc, %{
         type: :tool_call_completed,
         tool_call: %{id: id, name: name, arguments: args} = tool
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and
              (is_map(args) or is_binary(args)) do
    if Enum.any?(acc.tools, &(&1.id == id)),
      do: {:error, "duplicate tool call id"},
      else: {:ok, %{acc | tools: acc.tools ++ [tool]}}
  end

  defp collect(_, %{type: :tool_call_completed}), do: {:error, "malformed tool call"}

  defp collect(acc, %{type: :usage_updated, usage: usage}),
    do: {:ok, %{acc | usage: acc.usage ++ [usage]}}

  defp collect(acc, _), do: {:ok, acc}

  defp begin_tools(s, [], _catalog), do: after_boundary(s, false)

  defp begin_tools(s, [call | rest], catalog) do
    registry = catalog.registry

    with {:ok, descriptor} <- ToolRegistry.lookup(registry, call.name),
         invocation =
           Map.merge(
             identity(s),
             Map.merge(s.run.current_step, %{
               invocation_id: id("invocation"),
               tool_call_id: call.id,
               turn_id: s.conversation.turn_id,
               tool_name: call.name,
               tool_revision: descriptor.tool_revision,
               catalog_revision: catalog.revision,
               arguments: call.arguments
             })
           )
           |> Map.merge(Map.take(descriptor, [:collaboration_binding])) do
      prepare_tool(s, invocation, descriptor, catalog, {:direct, rest})
    else
      {:error, error} ->
        append_tool_result(
          s,
          %{tool_call_id: call.id, tool_name: call.name},
          tool_result({:error, error}),
          rest,
          catalog
        )
    end
  end

  defp accept_preparation(s, entry, result) do
    if entry.outer_token && not current_effect?(s, entry.outer_token) do
      s = %{s | preparation: nil}

      reject_prepared_tool(
        s,
        entry.invocation,
        entry.catalog,
        entry.continuation,
        Error.new(:cancelled, "enclosing invocation ended")
      )
    else
      complete_preparation(s, entry, result)
    end
  end

  defp complete_preparation(s, entry, result) do
    s = %{s | preparation: nil}

    case preparation_input(result, entry.invocation.arguments) do
      {:ok, input} ->
        admit_prepared_tool(
          s,
          %{entry.invocation | arguments: input},
          entry.descriptor,
          entry.catalog,
          entry.continuation
        )

      {:error, error} ->
        reject_prepared_tool(s, entry.invocation, entry.catalog, entry.continuation, error)
    end
  end

  defp prepare_tool(s, invocation, descriptor, catalog, continuation) do
    s = %{
      s
      | tool_admission_deadline:
          System.monotonic_time(:millisecond) + effect_timeout(s, s.limits.effect)
    }

    adapter = Keyword.get(s.opts, :hooks)

    if adapter && Code.ensure_loaded?(adapter) && function_exported?(adapter, :prepare_tool, 2) do
      token = make_ref()

      context =
        Map.put(
          Map.drop(base_effect_context(s, self(), token), [
            :provider_emit,
            :emit,
            :request_new_context
          ]),
          :input_kind,
          if(descriptor[:codex_input_kind] == :custom, do: :custom, else: :function)
        )

      context = feedback_context(context, self(), token)

      task =
        Task.Supervisor.async_nolink(s.supervisor, fn ->
          hook(s, :prepare_tool, [invocation, context], :allow)
        end)

      timeout = effect_timeout(s, s.limits.effect)
      generation = make_ref()
      timer = Process.send_after(self(), {:timeout, task.ref, generation}, timeout)

      %{
        s
        | preparation: %{
            task: task,
            token: token,
            timer: timer,
            timer_generation: generation,
            live_deadline: System.monotonic_time(:millisecond) + timeout,
            invocation: invocation,
            descriptor: descriptor,
            catalog: catalog,
            continuation: continuation,
            outer_token: if(match?({:nested, _}, continuation), do: s.effect.token, else: nil)
          }
      }
    else
      admit_prepared_tool(s, invocation, descriptor, catalog, continuation)
    end
  end

  defp preparation_input(:allow, input), do: {:ok, input}
  defp preparation_input({:allow, input}, _original), do: {:ok, input}

  defp preparation_input({:deny, reason}, _),
    do: {:error, Error.new(:forbidden, "tool preparation denied", details: %{reason: reason})}

  defp preparation_input({:error, %Error{} = error}, _), do: {:error, error}

  defp preparation_input(_, _),
    do: {:error, Error.new(:malformed_result, "invalid tool preparation result")}

  defp admit_prepared_tool(s, invocation, descriptor, catalog, continuation) do
    if admission_expired?(s) do
      stop(s, :deadline_exceeded)
    else
      validate_prepared_tool(s, invocation, descriptor, catalog, continuation)
    end
  end

  defp admission_expired?(s),
    do:
      is_integer(s.tool_admission_deadline) &&
        s.tool_admission_deadline <= System.monotonic_time(:millisecond)

  defp validate_prepared_tool(s, invocation, descriptor, catalog, continuation) do
    with {:ok, arguments} <- validate_tool_arguments(descriptor, invocation.arguments),
         invocation = %{invocation | arguments: arguments},
         {:ok, _} <- Policy.authorize_tool(catalog.authority, descriptor, invocation) do
      case continuation do
        {:nested, from} ->
          invoke_nested_tool(s, invocation, catalog, from)

        {:direct, rest} ->
          if descriptor.safety[:requires_approval] do
            start_effect(s, {:approval, invocation, descriptor, rest, catalog}, fn context ->
              context.interact.(%{kind: :permission, operation: invocation})
            end)
          else
            invoke_tool(s, invocation, descriptor, rest, catalog, [])
          end
      end
    else
      {:error, error} -> reject_prepared_tool(s, invocation, catalog, continuation, error)
    end
  end

  defp reject_prepared_tool(s, invocation, catalog, {:direct, rest}, error),
    do:
      append_tool_result(
        %{s | tool_admission_deadline: nil},
        invocation,
        tool_result({:error, error}),
        rest,
        catalog
      )

  defp reject_prepared_tool(s, _invocation, _catalog, {:nested, from}, error) do
    GenServer.reply(from, {:error, error})
    %{s | tool_admission_deadline: nil}
  end

  defp invoke_tool(s, invocation, descriptor, rest, catalog, approval) do
    if admission_expired?(s) do
      stop(s, :deadline_exceeded)
    else
      commit_tool(
        %{s | tool_admission_deadline: nil},
        invocation,
        descriptor,
        rest,
        catalog,
        approval
      )
    end
  end

  defp commit_tool(s, invocation, _descriptor, rest, catalog, approval) do
    resource_owner_pid = self()

    opts =
      [registry: catalog.registry, authority: catalog.authority, ephemeral_tool_authority: true] ++
        approval

    commit(s, {:tool_invoked, now(), invocation}, %{}, opts, fn s, prepared ->
      emit(s, %{type: :tool_started, invocation: invocation})

      start_effect(s, {:tool, invocation, rest, catalog}, fn context ->
        prepared = %{
          prepared
          | operation: Map.put(prepared.operation, :effective_authority, catalog.authority),
            host_context:
              Map.merge(
                prepared.host_context,
                Map.take(context, [
                  :interact,
                  :append_feedback,
                  :emit,
                  :catalog_snapshot,
                  :stage_catalog,
                  :request_new_context,
                  :nested_dispatch
                ])
              )
              |> Map.put(:resource_owner_pid, resource_owner_pid)
              |> Map.merge(goal_tool_context(s))
        }

        case Execution.dispatch(
               prepared,
               Keyword.merge(s.opts, registry: catalog.registry, authority: catalog.authority)
             ) do
          {:ok, [result]} -> {:ok, result}
          error -> error
        end
      end)
    end)
  end

  defp validate_tool_arguments(%{codex_input_kind: :custom}, arguments)
       when is_binary(arguments),
       do: {:ok, arguments}

  defp validate_tool_arguments(%{codex_input_kind: :custom}, _arguments),
    do: {:error, Error.new(:validation, "custom tool input must be a string")}

  defp validate_tool_arguments(descriptor, arguments),
    do: InputSchema.validate(descriptor.schema, arguments)

  defp append_tool_result(s, invocation, result, rest, catalog) do
    message = %{
      role: :tool,
      tool_call_id: invocation.tool_call_id,
      name: invocation.tool_name,
      result: result
    }

    checkpoint(s, %{s.conversation | messages: s.conversation.messages ++ [message]}, fn s ->
      emit(s, %{type: :tool_completed, message: message})
      if rest == [], do: after_boundary(s, true), else: begin_tools(s, rest, catalog)
    end)
  end

  defp after_boundary(s, tools?) do
    s = publish_catalog(s)

    case s.conversation.steering do
      [message | rest] ->
        checkpoint(s, %{s.conversation | steering: rest}, &begin_prompt(&1, message, :steering))

      [] when tools? and s.new_context_requested ->
        start_new_context_window(s)

      [] when tools? ->
        start_provider(s)

      [] ->
        start_effect(s, :stop_hook, fn context ->
          hook(s, :stop, [s.conversation.messages, context], :stop)
        end)
    end
  end

  defp start_new_context_window(s) do
    window = Map.get(s.conversation, :context_window, 1) + 1

    conversation =
      s.conversation
      |> Map.put(:messages, [])
      |> Map.put(:context_window, window)
      |> Map.update(
        :context_history,
        [%{window: window, provenance: :new_context_tool}],
        fn history ->
          history ++ [%{window: window, provenance: :new_context_tool}]
        end
      )

    checkpoint(%{s | new_context_requested: false}, conversation, fn next ->
      emit(next, %{type: :context_window_started, window: window})
      start_provider(next)
    end)
  end

  defp finish_turn(s, outcome) do
    turn = %{turn_id: s.conversation.turn_id, outcome: outcome, error: s.last_error}

    conversation =
      GoalBridge.queue(s, %{s.conversation | turns: s.conversation.turns ++ [turn]}, [
        {:turn_stopped, %{outcome: outcome}}
      ])

    checkpoint(s, conversation, fn s ->
      deliver_goal(s, fn s ->
        emit(
          s,
          Map.put(turn, :type, if(outcome == :completed, do: :turn_completed, else: :turn_failed))
        )

        case s.conversation.follow_up do
          [message | rest] ->
            checkpoint(s, %{s.conversation | follow_up: rest}, &begin_prompt(&1, message, :new))

          [] ->
            s = prepare_finish_resources(s, outcome)

            if s.resource_cleanup == :confirmed do
              input = Map.merge(identity(s), %{status: outcome, outcome: turn})

              commit(s, {:finish, now(), input}, %{}, [], fn s, _ ->
                s = acknowledge_finish_resources(%{s | phase: :terminal}, outcome)

                if s.resource_cleanup == :confirmed do
                  unbind_goal(s, fn s ->
                    input_activity(s, {:settled, Map.get(s.conversation, :mailbox, [])})

                    emit(s, %{
                      type: if(outcome == :completed, do: :run_completed, else: :run_failed),
                      outcome: turn
                    })

                    s
                  end)
                else
                  emit(s, %{type: :session_detach_failed, error: s.last_error})
                  s
                end
              end)
            else
              stop(s, :uncertain)
            end
        end
      end)
    end)
  end

  defp fail(s, reason), do: finish_turn(%{s | last_error: reason}, :failed)

  defp deliver_goal(%{goal_binding: nil} = s, next), do: next.(s)

  defp deliver_goal(s, next) do
    goal = Keyword.fetch!(s.opts, :goal)
    receipts = Map.get(s.conversation, :goal_outbox, [])
    binding = s.goal_binding

    task =
      Task.Supervisor.async_nolink(s.supervisor, fn ->
        with {:ok, responses} <- GoalBridge.deliver(goal, binding, receipts),
             {:ok, binding} <- Goal.attribution(goal, binding),
             do: {:ok, responses, binding}
      end)

    timeout =
      if s.cleanup_due,
        do: max(1, min(s.limits.commit, s.cleanup_due - System.monotonic_time(:millisecond))),
        else: effect_timeout(s, s.limits.commit)

    generation = make_ref()
    timer = Process.send_after(self(), {:goal_timeout, task.ref, generation}, timeout)
    %{s | goal_delivery: %{task: task, timer: timer, timer_generation: generation, next: next}}
  end

  defp goal_provider_usage(%{goal_binding: nil}, conversation, _usage, _identity),
    do: {:ok, conversation}

  defp goal_provider_usage(s, conversation, snapshots, identity) do
    ledger = Map.get(conversation, :goal_usage, elem(Usage.new(), 1))

    with {:ok, ledger, report} <- GoalBridge.report(ledger, snapshots, identity) do
      report = cumulative_report(report, identity)
      {:ok, GoalBridge.queue(s, Map.put(conversation, :goal_usage, ledger), [{:usage, report}])}
    end
  end

  defp checkpoint_provider_progress(%{goal_binding: nil} = s, event, _from) do
    if event.type != :response_completed, do: emit(s, event)
    {:reply, :ok, s}
  end

  defp checkpoint_provider_progress(s, event, from) do
    {:provider, identity, _catalog} = s.effect.role
    usage = Map.get(event, :usage)
    prior_usage = get_in(s.conversation, [:goal_stream_usage, identity.attempt_id]) || %{}

    baseline_usage =
      if usage,
        do:
          Map.merge(prior_usage, usage, fn _key, old, new ->
            if new in [nil, :unknown], do: old, else: new
          end)

    activity_key = {identity.attempt_id, :reasoning}
    activity = Map.get(s.conversation, :goal_activity, %{})

    thinking =
      event.type == :content_thinking_delta and
        is_binary(event[:delta]) and String.trim(event.delta) != "" and
        not Map.has_key?(activity, activity_key)

    events = if usage, do: [{:usage, cumulative_report(usage, identity)}], else: []

    events =
      if thinking,
        do: events ++ [{:item_completed, %{kind: :reasoning, text: event.delta}}],
        else: events

    if events == [] do
      if event.type != :response_completed, do: emit(s, event)
      {:reply, :ok, s}
    else
      previous_goal_id = s.goal_binding.expected_goal_id
      s = suspend_provider_idle(%{s | callers: [from | s.callers], provider_progress_from: from})

      {:noreply,
       deliver_goal(s, fn s ->
         baseline_events =
           if s.goal_binding.expected_goal_id != previous_goal_id do
             baseline = get_in(s.conversation, [:goal_stream_usage, identity.attempt_id])

             baseline =
               if baseline, do: Map.put(baseline, :attempt_id, identity.attempt_id), else: nil

             [
               {:turn_started,
                %{
                  mode: goal_mode(s),
                  trigger: Keyword.get(s.opts, :goal_trigger, :user),
                  usage_baseline: baseline
                }}
             ]
           else
             []
           end

         conversation =
           if thinking,
             do: Map.put(s.conversation, :goal_activity, Map.put(activity, activity_key, true)),
             else: s.conversation

         conversation =
           if usage,
             do:
               Map.update(
                 conversation,
                 :goal_stream_usage,
                 %{identity.attempt_id => baseline_usage},
                 &Map.put(&1, identity.attempt_id, baseline_usage)
               ),
             else: conversation

         conversation = GoalBridge.queue(s, conversation, baseline_events ++ events)

         checkpoint(s, conversation, fn s ->
           deliver_goal(s, fn s ->
             if event.type != :response_completed, do: emit(s, event)
             s = refresh_provider_idle(%{s | provider_progress_from: nil})
             reply(s, from, :ok)
           end)
         end)
       end)}
    end
  end

  defp cumulative_report(usage, identity) do
    metrics = Map.take(usage, [:input_tokens, :cached_tokens, :output_tokens, :reasoning_tokens])
    hash = digest(metrics)

    metrics
    |> Map.merge(Map.take(identity, [:run_id, :incarnation, :attempt_id, :step_id]))
    |> Map.put(
      :identity,
      "#{identity.run_id}:#{identity.incarnation}:#{identity.attempt_id}:#{hash}"
    )
    |> Map.put(:cumulative, true)
  end

  defp goal_mode(%{goal_binding: nil}), do: :execution
  defp goal_mode(s), do: s.goal_binding.mode
  defp goal_tool_context(%{goal_binding: nil}), do: %{}

  defp goal_tool_context(s),
    do: %{goal: Keyword.fetch!(s.opts, :goal), goal_binding: s.goal_binding}

  defp goal_text(%{content: text}) when is_binary(text), do: text

  defp goal_text(%{content: blocks}) when is_list(blocks),
    do: Enum.map_join(blocks, "", fn block -> Map.get(block, :text, "") end)

  defp goal_error_class(%{class: class}), do: class
  defp goal_error_class(_), do: :provider_error
  defp goal_abort_reason(:cancelled), do: :interrupted
  defp goal_abort_reason(reason), do: reason

  defp goal_tool_payload(invocation, result),
    do: %{
      tool: invocation.tool_name,
      success: result[:is_error] != true,
      handler_executed: true,
      settlement: :confirmed
    }

  defp unbind_goal(%{goal_binding: nil} = s, next), do: next.(s)

  defp unbind_goal(s, next) do
    goal = Keyword.fetch!(s.opts, :goal)
    binding = s.goal_binding
    task = Task.Supervisor.async_nolink(s.supervisor, fn -> Goal.unbind(goal, binding) end)

    timeout =
      if s.cleanup_due,
        do: max(1, min(s.limits.commit, s.cleanup_due - System.monotonic_time(:millisecond))),
        else: min(s.limits.commit, s.limits.cleanup)

    generation = make_ref()
    timer = Process.send_after(self(), {:goal_timeout, task.ref, generation}, timeout)

    %{
      s
      | goal_delivery: %{
          task: task,
          timer: timer,
          timer_generation: generation,
          kind: :unbind,
          next: next
        }
    }
  end

  defp checkpoint(s, conversation, next, opts \\ []) do
    input =
      Map.merge(identity(s), %{conversation: conversation, base_conversation: s.conversation})

    input =
      case Keyword.get(opts, :execution_deadline) do
        deadline when is_integer(deadline) or deadline == :infinity ->
          Map.put(input, :execution_deadline, deadline)

        _ ->
          input
      end

    commit(s, {:conversation_updated, now(), input}, %{}, [], fn s, _ ->
      next.(s)
    end)
  end

  defp commit(s, {kind, _, input} = command, meta, extra, next)
       when kind in [:provider_started, :tool_invoked] do
    reservation =
      if kind == :provider_started,
        do: "provider:#{input.attempt_id}",
        else: "tool:#{input.invocation_id}"

    case Budget.reserve(s.run.execution_budget, reservation) do
      {:ok, _, _} -> enqueue_or_commit(s, command, meta, extra, next)
      {:error, error} -> finish_turn(%{s | last_error: error}, :failed)
    end
  end

  defp commit(s, command, meta, extra, next), do: enqueue_or_commit(s, command, meta, extra, next)

  defp enqueue_or_commit(%{commit: nil} = s, command, meta, extra, next),
    do: do_commit(s, command, meta, extra, next)

  defp enqueue_or_commit(s, {kind, at, input} = command, meta, extra, next) do
    command =
      if kind in [:provider_completed, :tool_completed] and
           is_map(get_in(input, [:context, :conversation])),
         do: {kind, at, Map.put(input, :base_conversation, s.conversation)},
         else: command

    %{s | commit_queue: :queue.in({command, meta, extra, next}, s.commit_queue)}
  end

  defp enqueue_or_commit(s, command, meta, extra, next),
    do: %{s | commit_queue: :queue.in({command, meta, extra, next}, s.commit_queue)}

  defp rebase_queued_command(s, {kind, at, %{base_conversation: base} = input})
       when kind in [:provider_completed, :tool_completed] do
    desired = get_in(input, [:context, :conversation])
    conversation = merge_conversation(base, s.conversation, desired)

    conversation =
      if Map.has_key?(desired, :goal_outbox) do
        appended = Enum.drop(desired.goal_outbox, length(Map.get(base, :goal_outbox, [])))
        revision = s.run.expected_revision + 1

        appended =
          Enum.with_index(appended, fn receipt, index ->
            %{
              receipt
              | revision: revision,
                receipt_id:
                  "#{receipt.run_id}:#{receipt.incarnation}:#{revision}:#{receipt.type}:#{index}"
            }
          end)

        Map.put(conversation, :goal_outbox, Map.get(s.conversation, :goal_outbox, []) ++ appended)
      else
        conversation
      end

    {kind, at,
     input |> Map.delete(:base_conversation) |> put_in([:context, :conversation], conversation)}
  end

  defp rebase_queued_command(s, {kind, at, input} = command)
       when kind == :conversation_updated and is_map(input) do
    base = Map.get(input, :base_conversation)
    desired = Map.get(input, :conversation)
    current = s.conversation

    if is_map(base) and is_map(desired) and is_map(current),
      do: {kind, at, Map.put(input, :conversation, merge_conversation(base, current, desired))},
      else: command
  end

  defp rebase_queued_command(_s, command), do: command

  defp merge_conversation(base, current, desired) do
    merged =
      Enum.reduce([:messages, :steering, :follow_up, :mailbox], desired, fn key, acc ->
        base_items = Map.get(base, key, [])
        current_items = Map.get(current, key, [])
        desired_items = Map.get(desired, key, [])

        suffix =
          if Enum.take(desired_items, length(base_items)) == base_items,
            do: Enum.drop(desired_items, length(base_items)),
            else: desired_items

        Map.put(acc, key, current_items ++ suffix)
      end)

    merged = Map.update!(merged, :messages, &HostFeedback.merge_messages/1)

    Map.put(
      merged,
      :host_feedback,
      HostFeedback.merge(
        Map.get(current, :host_feedback, []),
        Map.get(desired, :host_feedback, [])
      )
    )
  end

  defp do_commit(s, command, meta, extra, next) do
    opts = Keyword.merge(s.opts, extra)

    task =
      Task.Supervisor.async_nolink(s.supervisor, fn ->
        Execution.commit(
          Keyword.fetch!(s.opts, :store),
          Keyword.fetch!(s.opts, :context),
          s.run,
          Map.put(meta, :command, command),
          opts
        )
      end)

    timeout =
      if s.cleanup_due,
        do: max(1, min(s.limits.commit, s.cleanup_due - System.monotonic_time(:millisecond))),
        else: s.limits.commit

    generation = make_ref()
    timer = Process.send_after(self(), {:timeout, task.ref, generation}, timeout)
    %{s | commit: %{task: task, timer: timer, timer_generation: generation, next: next}}
  end

  defp start_effect(s, role, function) do
    owner = self()
    token = make_ref()

    context = base_effect_context(s, owner, token)

    context =
      case role do
        {:tool, invocation, _, _} ->
          Map.merge(
            context,
            trusted_effect_context(
              s,
              token,
              catalog_from_role(role),
              owner,
              invocation,
              invocation
            )
          )

        _ ->
          context
      end

    task = Task.Supervisor.async_nolink(s.supervisor, fn -> function.(context) end)

    configured =
      if match?({:provider, _, _}, role),
        do: s.limits.provider_idle || s.limits.effect,
        else: s.limits.effect

    timeout = effect_timeout(s, configured)

    timeout =
      if match?({:approval, _, _, _, _}, role) && is_integer(s.tool_admission_deadline),
        do: max(1, min(timeout, s.tool_admission_deadline - System.monotonic_time(:millisecond))),
        else: timeout

    generation = make_ref()
    timer = Process.send_after(self(), {:timeout, task.ref, generation}, timeout)

    %{
      s
      | effect: %{
          task: task,
          timer: timer,
          timer_generation: generation,
          role: role,
          token: token
        },
        effect_live_deadline: System.monotonic_time(:millisecond) + timeout,
        phase: :running
    }
  end

  defp hook(s, function, args, default) do
    adapter = Keyword.get(s.opts, :hooks)

    if adapter && Code.ensure_loaded?(adapter) &&
         function_exported?(adapter, function, length(args)),
       do: apply(adapter, function, args),
       else: default
  end

  defp catalog_from_role({:tool, _invocation, _rest, catalog}), do: catalog

  defp base_effect_context(s, owner, token) do
    Keyword.get(s.opts, :provider_context, %{})
    |> Map.put(:interact, fn request ->
      GenServer.call(owner, {:interact, token, request}, :infinity)
    end)
    |> Map.put(:emit, fn event -> GenServer.call(owner, {:chunk, token, event}, :infinity) end)
    |> Map.put(:provider_emit, fn event ->
      GenServer.call(owner, {:provider_chunk, token, event}, :infinity)
    end)
    |> Map.put(:request_new_context, fn ->
      GenServer.call(owner, {:request_new_context, token}, :infinity)
    end)
  end

  defp trusted_effect_context(s, token, catalog, owner, producer, boundary) do
    base_effect_context(s, owner, token)
    |> feedback_context(owner, token)
    |> Map.put(:catalog_snapshot, catalog)
    |> Map.put(:stage_catalog, fn update ->
      GenServer.call(owner, {:stage_catalog, token, update}, :infinity)
    end)
    |> Map.put(:nested_dispatch, fn request ->
      GenServer.call(owner, {:nested_tool, token, request}, :infinity)
    end)
    |> Map.put(:resource_owner_pid, owner)
    |> Map.put(:producer_invocation, producer)
    |> Map.put(:publication_boundary, boundary)
  end

  defp feedback_context(context, owner, token) do
    Map.put(context, :append_feedback, fn payload ->
      GenServer.call(owner, {:append_feedback, token, payload}, :infinity)
    end)
  end

  defp feedback_producer(%{stopping: nil, phase: phase} = s, token)
       when phase not in [:terminal, :cancelling, :storage_failed, :recovery_required] do
    cond do
      s.preparation && s.preparation.token == token && s.preparation.task &&
          (is_nil(s.preparation.outer_token) ||
             (s.effect && s.effect.token == s.preparation.outer_token && s.effect.task)) ->
        {:ok, s.preparation.invocation, outer_invocation(s.preparation.invocation, s)}

      s.nested && s.nested.token == token && s.nested.task && s.effect && s.effect.task ->
        {:ok, s.nested.invocation, outer_invocation(s.nested.invocation, s)}

      s.effect && s.effect.token == token && s.effect.task &&
          match?({:tool, _, _, _}, s.effect.role) ->
        {:tool, invocation, _, _} = s.effect.role
        {:ok, invocation, invocation}

      true ->
        stale_feedback()
    end
  end

  defp feedback_producer(_, _), do: stale_feedback()

  defp stale_feedback,
    do: {:error, Error.new(:resource_conflict, "feedback producer is no longer live")}

  defp stop(s, reason) do
    s = invalidate_run_timer(s)
    task_stop = if s.effect, do: kill_task(s.effect), else: :ok
    if s.preparation, do: kill_task(s.preparation)
    reject_nested_preparation(s, Error.new(:cancelled, "run cancelled"))
    if s.goal_delivery, do: kill_task(s.goal_delivery)

    if s.nested do
      if s.nested.task, do: kill_task(s.nested)
      GenServer.reply(s.nested.from, {:error, Error.new(:cancelled, "run cancelled")})
    end

    if s.interaction,
      do: GenServer.reply(s.interaction.from, {:error, Error.new(:cancelled, "run cancelled")})

    Enum.each(s.callers, &GenServer.reply(&1, {:error, Error.new(:cancelled, "run stopped")}))
    reject_jobs(s.jobs)

    s = s |> discard_pending_catalog() |> cleanup_resources()

    s = %{
      s
      | effect: nil,
        preparation: nil,
        goal_delivery: nil,
        nested: nil,
        nested_admission: nil,
        commit_queue: :queue.new(),
        interaction: nil,
        jobs: :queue.new(),
        callers: [],
        admission: nil,
        new_context_requested: false,
        phase: :cancelling,
        cleanup_due: s.cleanup_due || System.monotonic_time(:millisecond) + s.limits.cleanup,
        stopping:
          s.stopping ||
            %{
              reason: reason,
              uncertain:
                task_stop != :ok or
                  s.resource_cleanup != :confirmed or
                  map_size(Map.get(s.run, :active_tools, %{})) > 0 or
                  not is_nil(Map.get(s.run, :active_provider))
            }
    }

    if s.commit, do: s, else: advance_stop(s)
  end

  defp advance_stop(%{commit: commit} = s) when not is_nil(commit), do: s

  defp advance_stop(s) do
    cond do
      s.goal_delivery != nil ->
        s

      s.effect != nil ->
        s

      Map.get(s.conversation, :goal_outbox, []) != [] and s.run.state == :running ->
        deliver_goal(s, &advance_stop/1)

      RunKernel.terminal?(s.run.state) ->
        %{s | stopping: nil, phase: :terminal}

      s.run.state == :running and Map.get(s.conversation, :queue_status) != :suspended ->
        conversation =
          s.conversation
          |> Map.put(:pending_interaction, nil)
          |> Map.put(:queue_status, :suspended)

        conversation =
          GoalBridge.queue(s, conversation, [
            {:turn_aborted, %{reason: goal_abort_reason(s.stopping.reason)}}
          ])

        checkpoint(s, conversation, & &1)

      s.run.state == :cancelling ->
        uncertain = s.stopping.uncertain || s.stopping.reason == :uncertain

        settlement =
          if uncertain,
            do: %{
              certainty: :uncertain,
              evidence: %{reason: "worker stopped; external effects require host reconciliation"}
            },
            else: %{certainty: :confirmed, settled: RunKernel.cleanup_requirements(s.run)}

        # Keep the stop request until the cleanup commit has succeeded.
        commit(%{s | stopping: nil}, {:cleanup_settled, now(), settlement}, %{}, [], fn s, _ ->
          s = %{s | phase: :terminal}

          unbind_goal(s, fn s ->
            emit(s, %{type: :run_cancelled, outcome: s.run.outcome, state: s.run.state})
            s
          end)
        end)

      true ->
        command =
          if s.stopping.reason == :deadline_exceeded, do: :deadline_exceeded, else: :cancel

        commit(s, {command, now()}, %{}, [], fn s, _ -> s end)
    end
  end

  defp storage_failed(s, error) do
    s = invalidate_run_timer(s)
    if s.effect, do: kill_task(s.effect)
    if s.preparation, do: kill_task(s.preparation)
    reject_nested_preparation(s, error)
    if s.goal_delivery, do: kill_task(s.goal_delivery)
    if s.nested && s.nested.task, do: kill_task(s.nested)
    if s.nested, do: GenServer.reply(s.nested.from, {:error, error})
    if s.interaction, do: GenServer.reply(s.interaction.from, {:error, error})
    Enum.each(s.callers, &GenServer.reply(&1, {:error, error}))
    reject_jobs(s.jobs)
    emit(s, %{type: :storage_failed, error: error, recovery_required: true})

    s = s |> discard_pending_catalog() |> cleanup_resources()

    %{
      s
      | phase: :storage_failed,
        interaction: nil,
        conversation: Map.put(s.conversation, :pending_interaction, nil),
        goal_delivery: nil,
        effect: nil,
        preparation: nil,
        nested: nil,
        nested_admission: nil,
        commit_queue: :queue.new(),
        stopping: nil,
        jobs: :queue.new(),
        callers: [],
        last_error: error
    }
  end

  defp reject_jobs(jobs) do
    Enum.each(:queue.to_list(jobs), fn job ->
      case job do
        {:interact, _, _, from} ->
          GenServer.reply(from, {:error, Error.new(:cancelled, "run stopped")})

        {:prepared_tool, %{continuation: {:nested, from}}, _} ->
          GenServer.reply(from, {:error, Error.new(:cancelled, "run stopped")})

        _ ->
          :ok
      end
    end)
  end

  defp reply(s, from, value) do
    GenServer.reply(from, value)
    %{s | callers: List.delete(s.callers, from)}
  end

  defp acknowledge_admission(%{admission: nil} = s, _), do: s

  defp acknowledge_admission(%{admission: {from, id}} = s, result) do
    result = if result == :ok, do: {:ok, %{message_id: id}}, else: result
    %{reply(s, from, result) | admission: nil}
  end

  defp tool_result({:ok, result}) when is_map(result), do: Map.put_new(result, :is_error, false)
  defp tool_result({:error, error}), do: %{is_error: true, error: error}
  defp tool_result(_), do: %{is_error: true, error: "malformed tool result"}

  defp reject_nested_preparation(%{preparation: %{continuation: {:nested, from}}}, error),
    do: GenServer.reply(from, {:error, error})

  defp reject_nested_preparation(_, _), do: :ok

  defp current_effect?(%{preparation: %{token: token, task: %{ref: _}}, stopping: nil}, token),
    do: true

  defp current_effect?(%{effect: %{token: token}, stopping: nil}, token), do: true

  defp current_effect?(%{nested: %{token: token, task: %{ref: _}}, stopping: nil}, token),
    do: true

  defp current_effect?(_, _), do: false

  defp invalidate_run_timer(s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: nil, timer_generation: nil}
  end

  defp complete_nested(%{nested: nested} = s, normalized) do
    s = discard_failed_catalog(s, nested.invocation, normalized)

    if tool_settlement(nested.catalog, nested.invocation, normalized) == :uncertain do
      GenServer.reply(nested.from, normalized)
      stop(%{s | nested: nil, last_error: uncertain_error(normalized)}, :uncertain)
    else
      settle_nested_result(s, nested, normalized)
    end
  end

  defp settle_nested_result(s, nested, normalized) do
    result = tool_result(normalized)

    conversation =
      GoalBridge.queue(s, s.conversation, [
        {:tool_finished, goal_tool_payload(nested.invocation, result)}
      ])

    completion =
      nested.invocation
      |> Map.put(:result, result)
      |> Map.put(:context, Map.put(s.run.context, :conversation, conversation))

    s =
      case s.interaction do
        %{token: token, from: waiter} when token == nested.token ->
          GenServer.reply(waiter, {:error, Error.new(:cancelled, "nested invocation ended")})
          %{s | interaction: nil}

        _ ->
          s
      end

    next = fn next_state, _prepared ->
      next_state = settle_nested_catalog(next_state, nested.invocation, normalized)

      deliver_goal(next_state, fn acknowledged ->
        GenServer.reply(nested.from, normalized)
        %{acknowledged | nested: nil}
      end)
    end

    # Expire all producer callbacks immediately; acknowledged successful settlement
    # alone makes staged discovery eligible at the enclosing publication boundary.
    pending = %{nested | task: nil, timer: nil, timer_generation: nil, live_deadline: nil}
    drive(commit(%{s | nested: pending}, {:tool_completed, now(), completion}, %{}, [], next))
  end

  defp tool_settlement(catalog, invocation, normalized) do
    case ToolRegistry.lookup(catalog.registry, invocation.tool_name) do
      {:ok, %{tool_revision: revision, safety: safety}}
      when revision == invocation.tool_revision ->
        ToolEffects.settlement(normalized, safety)

      _ ->
        :uncertain
    end
  end

  defp uncertain_error({:error, %Error{} = error}), do: error

  defp uncertain_error(_),
    do: Error.new(:unknown_outcome, "tool result lacks trustworthy settlement evidence")

  defp valid_provider_event?(%{type: type, delta: delta})
       when type in [:content_text_delta, :content_thinking_delta, :tool_call_arguments_delta],
       do: is_binary(delta)

  defp valid_provider_event?(%{type: :tool_call_completed} = event),
    do: match?({:ok, _}, collect(%{tools: []}, event))

  defp valid_provider_event?(
         %{type: :response_completed, message: %{role: :assistant, content: content}} = event
       ),
       do: (is_binary(content) or is_list(content)) and valid_usage_event?(event)

  defp valid_provider_event?(%{type: :usage_updated, usage: usage}),
    do: valid_normalized_usage?(usage)

  defp valid_provider_event?(%{type: :usage_updated}), do: false

  defp valid_provider_event?(%{type: type}),
    do: type in [:response_started, :tool_call_started, :provider_hosted_event, :usage_updated]

  defp valid_provider_event?(_), do: false

  defp valid_usage_event?(event),
    do:
      not Map.has_key?(event, :usage) or is_nil(event.usage) or
        valid_normalized_usage?(event.usage)

  defp valid_normalized_usage?(usage) when is_map(usage),
    do:
      Enum.all?([:input_tokens, :cached_tokens, :output_tokens, :reasoning_tokens], fn key ->
        value = Map.get(usage, key)
        value in [nil, :unknown] or (is_integer(value) and value >= 0)
      end)

  defp valid_normalized_usage?(_), do: false

  defp cumulative_provider_progress?(%{goal_binding: nil}, _event), do: true

  defp cumulative_provider_progress?(s, %{usage: usage}) when is_map(usage) do
    {:provider, identity, _} = s.effect.role
    previous = get_in(s.conversation, [:goal_stream_usage, identity.attempt_id]) || %{}

    Enum.all?([:input_tokens, :cached_tokens, :output_tokens, :reasoning_tokens], fn key ->
      old = previous[key]
      new = usage[key]
      not (is_integer(old) and is_integer(new) and new < old)
    end)
  end

  defp cumulative_provider_progress?(_s, _event), do: true

  defp refresh_provider_idle(%{phase: :waiting_interaction} = s), do: s
  defp refresh_provider_idle(%{limits: %{provider_idle: nil}} = s), do: s

  defp refresh_provider_idle(s) do
    if s.effect.timer, do: Process.cancel_timer(s.effect.timer)
    generation = make_ref()
    timeout = effect_timeout(s, s.limits.provider_idle)
    timer = Process.send_after(self(), {:timeout, s.effect.task.ref, generation}, timeout)

    %{
      s
      | effect: %{s.effect | timer: timer, timer_generation: generation},
        effect_live_deadline: System.monotonic_time(:millisecond) + timeout
    }
  end

  defp suspend_provider_idle(%{limits: %{provider_idle: nil}} = s), do: s

  defp suspend_provider_idle(s) do
    if s.effect.timer, do: Process.cancel_timer(s.effect.timer)
    %{s | effect: %{s.effect | timer: nil, timer_generation: nil}, effect_live_deadline: nil}
  end

  defp effect_timeout(%{run: %{deadline: :infinity}}, configured), do: configured
  defp effect_timeout(s, configured), do: max(1, min(configured, s.run.deadline - now()))

  defp run_timer(%{deadline: :infinity}), do: {nil, nil}

  defp run_timer(run) do
    generation = make_ref()

    timer =
      Process.send_after(
        self(),
        {:deadline, run.run_id, run.incarnation, generation},
        max(0, run.deadline - now())
      )

    {timer, generation}
  end

  defp pause_deadlines(s) do
    run_remaining =
      if(s.run.deadline == :infinity, do: :infinity, else: max(0, s.run.deadline - now()))

    effect_remaining =
      case s.effect_live_deadline do
        deadline when is_integer(deadline) ->
          max(0, deadline - System.monotonic_time(:millisecond))

        _ ->
          nil
      end

    nested_remaining =
      case s.nested && s.nested.live_deadline do
        deadline when is_integer(deadline) ->
          max(0, deadline - System.monotonic_time(:millisecond))

        _ ->
          nil
      end

    admission_remaining =
      if is_integer(s.tool_admission_deadline),
        do: max(0, s.tool_admission_deadline - System.monotonic_time(:millisecond))

    preparation_remaining =
      if s.preparation,
        do: max(0, s.preparation.live_deadline - System.monotonic_time(:millisecond))

    if s.preparation && s.preparation.timer, do: Process.cancel_timer(s.preparation.timer)
    if s.timer, do: Process.cancel_timer(s.timer)
    if s.effect && s.effect.timer, do: Process.cancel_timer(s.effect.timer)
    if s.nested && s.nested.timer, do: Process.cancel_timer(s.nested.timer)

    %{
      s
      | timer: nil,
        timer_generation: nil,
        effect: if(s.effect, do: %{s.effect | timer: nil, timer_generation: nil}, else: nil),
        nested: if(s.nested, do: %{s.nested | timer: nil, timer_generation: nil}, else: nil),
        effect_live_deadline: nil,
        preparation:
          if(s.preparation, do: %{s.preparation | timer: nil, timer_generation: nil}, else: nil),
        paused_preparation_remaining: preparation_remaining,
        paused_admission_remaining: admission_remaining,
        paused_run_remaining: run_remaining,
        paused_effect_remaining: effect_remaining,
        paused_nested_remaining: nested_remaining
    }
  end

  defp resume_deadline(%{paused_run_remaining: remaining}) when is_integer(remaining),
    do: now() + remaining

  defp resume_deadline(s), do: s.run.deadline

  defp resume_deadlines(s) do
    {timer, generation} = run_timer(s.run)

    s = %{
      s
      | timer: timer,
        timer_generation: generation,
        tool_admission_deadline:
          if(is_integer(s.paused_admission_remaining),
            do: System.monotonic_time(:millisecond) + s.paused_admission_remaining,
            else: s.tool_admission_deadline
          ),
        paused_admission_remaining: nil
    }

    s =
      case {s.effect, s.paused_effect_remaining} do
        {%{task: task} = effect, remaining} when is_integer(remaining) and remaining >= 0 ->
          generation = make_ref()
          timer = Process.send_after(self(), {:timeout, task.ref, generation}, remaining)

          %{
            s
            | effect: %{effect | timer: timer, timer_generation: generation},
              effect_live_deadline: System.monotonic_time(:millisecond) + remaining,
              paused_run_remaining: nil,
              paused_effect_remaining: nil
          }

        _ ->
          %{s | paused_run_remaining: nil, paused_effect_remaining: nil}
      end

    s =
      case {s.preparation, s.paused_preparation_remaining} do
        {%{task: %{ref: _} = task} = preparation, remaining}
        when is_integer(remaining) and remaining >= 0 ->
          generation = make_ref()
          timer = Process.send_after(self(), {:timeout, task.ref, generation}, remaining)

          %{
            s
            | preparation: %{
                preparation
                | timer: timer,
                  timer_generation: generation,
                  live_deadline: System.monotonic_time(:millisecond) + remaining
              },
              paused_preparation_remaining: nil
          }

        _ ->
          %{s | paused_preparation_remaining: nil}
      end

    case {s.nested, s.paused_nested_remaining} do
      {%{task: task} = nested, remaining} when is_integer(remaining) and remaining >= 0 ->
        generation = make_ref()
        timer = Process.send_after(self(), {:nested_timeout, task.ref, generation}, remaining)

        %{
          s
          | nested: %{
              nested
              | timer: timer,
                timer_generation: generation,
                live_deadline: System.monotonic_time(:millisecond) + remaining
            },
            paused_nested_remaining: nil
        }

      _ ->
        %{s | paused_nested_remaining: nil}
    end
  end

  defp stage_catalog(s, token, update) do
    with :ok <- ToolCatalog.fence(update, s.run),
         :ok <- catalog_reconciliation_allowed(s, token) do
      case catalog_receipt(s, update) do
        {:ok, receipt} ->
          {:ok, receipt, s}

        {:error, %Error{} = error} ->
          {:error, error}

        :error ->
          with :ok <- catalog_stage_allowed(s, token),
               :ok <- no_pending_catalog(s),
               {:ok, catalog} <- ToolCatalog.validate(update, s.catalog.revision, s.run) do
            receipt = ToolCatalog.receipt(catalog, :staged)
            {producer_invocation_id, boundary_invocation_id} = catalog_owners(s, token)

            next = %{
              s
              | pending_catalog: %{
                  catalog: catalog,
                  update: update,
                  producer_invocation_id: producer_invocation_id,
                  boundary_invocation_id: boundary_invocation_id,
                  producer_settled?: false
                },
                catalog_receipts: remember_receipt(s.catalog_receipts, update, receipt)
            }

            {:ok, receipt, next}
          end
      end
    end
  end

  defp catalog_owners(%{nested: %{token: token, invocation: invocation}, effect: effect}, token) do
    boundary =
      case effect.role do
        {:tool, outer, _, _} -> outer.invocation_id
        _ -> invocation.invocation_id
      end

    {invocation.invocation_id, boundary}
  end

  defp catalog_owners(%{effect: %{role: {:tool, invocation, _, _}}}, _token),
    do: {invocation.invocation_id, invocation.invocation_id}

  defp catalog_reconciliation_allowed(_s, nil), do: :ok

  defp catalog_reconciliation_allowed(%{effect: %{token: token}, stopping: nil}, token), do: :ok

  defp catalog_reconciliation_allowed(
         %{nested: %{token: token, task: %{ref: _}}, stopping: nil},
         token
       ),
       do: :ok

  defp catalog_reconciliation_allowed(_s, _token),
    do: {:error, Error.new(:resource_conflict, "stale catalog publication owner")}

  defp catalog_stage_allowed(
         %{phase: :running, stopping: nil, interaction: nil, effect: %{role: {:tool, _, _, _}}},
         nil
       ),
       do: :ok

  defp catalog_stage_allowed(
         %{
           phase: :running,
           stopping: nil,
           interaction: nil,
           effect: %{role: {:tool, _, _, _}, token: token}
         },
         token
       ),
       do: :ok

  defp catalog_stage_allowed(
         %{
           phase: :running,
           stopping: nil,
           interaction: nil,
           nested: %{token: token, task: %{ref: _}}
         },
         token
       ),
       do: :ok

  defp catalog_stage_allowed(_s, _token),
    do: {:error, Error.new(:resource_conflict, "catalog can only be staged by an active tool")}

  defp no_pending_catalog(%{pending_catalog: nil}), do: :ok

  defp no_pending_catalog(_s),
    do: {:error, Error.new(:resource_conflict, "another catalog publication is pending")}

  defp catalog_receipt(s, update) do
    publication_id = Map.get(update, :publication_id, Map.get(update, "publication_id"))

    case Enum.find(s.catalog_receipts, &(&1.publication_id == publication_id)) do
      %{update: ^update, receipt: receipt} ->
        {:ok, receipt}

      nil ->
        :error

      _ ->
        {:error,
         Error.new(:resource_conflict, "publication id was already used for another catalog")}
    end
  end

  defp remember_receipt(receipts, update, receipt) do
    entry = %{publication_id: receipt.publication_id, update: update, receipt: receipt}

    [entry | Enum.reject(receipts, &(&1.publication_id == receipt.publication_id))]
    |> Enum.take(16)
  end

  defp discard_failed_catalog(s, invocation, {:ok, result}) when is_map(result) do
    if Map.get(result, :is_error, Map.get(result, "is_error", false)) == true,
      do: discard_owned_catalog(s, invocation),
      else: s
  end

  defp discard_failed_catalog(
         %{pending_catalog: %{producer_invocation_id: _} = pending} = s,
         %{invocation_id: invocation_id},
         _result
       ),
       do:
         if(invocation_id in [pending.producer_invocation_id, pending.boundary_invocation_id],
           do: discard_pending_catalog(s),
           else: s
         )

  defp discard_failed_catalog(s, _invocation, _result), do: s

  defp discard_owned_catalog(
         %{pending_catalog: %{producer_invocation_id: _} = pending} = s,
         %{invocation_id: invocation_id}
       ),
       do:
         if(invocation_id in [pending.producer_invocation_id, pending.boundary_invocation_id],
           do: discard_pending_catalog(s),
           else: s
         )

  defp discard_owned_catalog(s, _invocation), do: s

  defp discard_pending_catalog(%{pending_catalog: nil} = s), do: s

  defp discard_pending_catalog(%{pending_catalog: pending} = s) do
    receipts =
      Enum.reject(s.catalog_receipts, &(&1.publication_id == pending.catalog.publication_id))

    %{s | pending_catalog: nil, catalog_receipts: receipts}
  end

  defp settle_nested_catalog(
         %{pending_catalog: %{producer_invocation_id: _} = pending} = s,
         invocation,
         {:ok, result}
       )
       when is_map(result) do
    if pending.producer_invocation_id == invocation.invocation_id and
         Map.get(result, :is_error, Map.get(result, "is_error", false)) != true,
       do: %{s | pending_catalog: %{pending | producer_settled?: true}},
       else: s
  end

  defp settle_nested_catalog(s, _invocation, _result), do: s

  defp settle_catalog_producer(
         %{pending_catalog: %{producer_invocation_id: _} = pending} = s,
         invocation,
         result
       ) do
    if pending.producer_invocation_id == invocation.invocation_id and
         Map.get(result, :is_error, false) != true,
       do: %{s | pending_catalog: %{pending | producer_settled?: true}},
       else: s
  end

  defp settle_catalog_producer(s, _invocation, _result), do: s

  defp publish_catalog(%{pending_catalog: nil} = s), do: s

  defp publish_catalog(%{pending_catalog: %{producer_settled?: false}} = s),
    do: discard_pending_catalog(s)

  defp publish_catalog(%{pending_catalog: pending} = s) do
    receipt = ToolCatalog.receipt(pending.catalog, :published)
    emit(s, %{type: :catalog_published, catalog_revision: pending.catalog.revision})

    %{
      s
      | catalog: pending.catalog,
        resource_registries:
          Enum.uniq(s.resource_registries ++ resource_registries(pending.catalog.registry)),
        pending_catalog: nil,
        catalog_receipts: remember_receipt(s.catalog_receipts, pending.update, receipt)
    }
  end

  defp resource_registries(%ToolRegistry{tools: tools}) do
    tools
    |> Map.values()
    |> Enum.flat_map(fn descriptor ->
      case get_in(descriptor, [:backend_context, :context]) do
        context when is_map(context) ->
          [:resource_registry, :session_registry]
          |> Enum.map(&Map.get(context, &1))
          |> Enum.filter(&is_pid/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp resource_registries(_), do: []

  defp cleanup_resources(%{resource_cleanup: status} = s) when status != :not_requested,
    do: cleanup_session_resources(s)

  defp cleanup_resources(s) do
    if Keyword.has_key?(s.opts, :session_binding),
      do: cleanup_session_resources(s),
      else: cleanup_run_resources(s)
  end

  defp prepare_finish_resources(s, :completed) do
    case Keyword.get(s.opts, :session_binding) do
      nil ->
        cleanup_resources(s)

      binding ->
        case Session.prepare_detach(binding) do
          :ok -> %{s | resource_cleanup: :confirmed}
          {:error, error} -> %{s | resource_cleanup: {:uncertain, error}, last_error: error}
        end
    end
  end

  defp prepare_finish_resources(s, _), do: cleanup_resources(s)

  defp acknowledge_finish_resources(s, :completed) do
    case Keyword.get(s.opts, :session_binding) do
      nil ->
        s

      binding ->
        input_activity(s, {:settled, Map.get(s.conversation, :mailbox, [])})

        case Session.detach(binding) do
          {:ok, _} ->
            s

          {:error, error} ->
            s = cleanup_session_resources(s)
            %{s | resource_cleanup: {:uncertain, error}, last_error: error}
        end
    end
  end

  defp acknowledge_finish_resources(s, _outcome), do: s

  defp cleanup_session_resources(s) do
    case Keyword.get(s.opts, :session_binding) do
      nil ->
        s

      binding ->
        result = Session.close(binding, run_fenced: true)

        status =
          if match?({:ok, %{status: :confirmed}}, result),
            do: :confirmed,
            else: {:uncertain, result}

        %{s | resource_cleanup: status}
    end
  end

  defp cleanup_run_resources(s) do
    # Run all registry requests concurrently under one run cleanup deadline.
    # Killing a waiter on timeout does not assert that external cleanup finished;
    # the registry keeps its own supervised work and reconciliation evidence.
    tasks =
      Enum.map(s.resource_registries, fn registry ->
        Task.Supervisor.async_nolink(s.supervisor, fn ->
          try do
            ResourceRegistry.close_owner(registry, s.run.run_id)
          catch
            :exit, reason -> {:error, inspect(reason)}
          end
        end)
      end)

    results =
      tasks
      |> Task.yield_many(s.limits.cleanup)
      |> Enum.map(fn
        {_task, {:ok, result}} ->
          result

        {_task, {:exit, reason}} ->
          {:error, inspect(reason)}

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          {:error, :cleanup_deadline_exceeded}
      end)

    confirmed? =
      Enum.all?(results, fn
        {:ok, entries} -> Enum.all?(entries, &match?({:ok, _}, &1))
        _ -> false
      end)

    status = if confirmed?, do: :confirmed, else: {:uncertain, results}
    %{s | resource_cleanup: status}
  end

  defp catalog_publication(nil, _status), do: nil
  defp catalog_publication(%{publication_id: nil}, _status), do: nil
  defp catalog_publication(catalog, status), do: ToolCatalog.receipt(catalog, status)

  defp clear_task(entry) do
    Process.demonitor(entry.task.ref, [:flush])
    if entry.timer, do: Process.cancel_timer(entry.timer)
  end

  defp kill_task(%{task: nil}), do: :ok

  defp kill_task(entry) do
    clear_task(entry)
    ref = Process.monitor(entry.task.pid)
    Process.exit(entry.task.pid, :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      100 ->
        Process.demonitor(ref, [:flush])
        :uncertain
    end
  end

  defp emit(s, event) do
    metadata =
      identity(s)
      |> Map.merge(Map.get(s.run, :current_step) || %{})
      |> Map.put(:turn_id, s.conversation.turn_id)

    event = Map.merge(event, metadata)

    if pid = Keyword.get(s.opts, :subscriber),
      do: send(pid, {:agent_runtime, s.run.run_id, event})

    :ok
  end

  defp identity(s), do: Map.take(s.run, [:run_id, :incarnation])

  defp input_identity(s),
    do: Map.put(identity(s), :session_binding, Keyword.get(s.opts, :session_binding))

  defp input_runtimes(opts, registry) do
    discovered =
      registry.tools
      |> Map.values()
      |> Enum.flat_map(fn descriptor ->
        case descriptor[:backend_context] do
          %{family: :collaboration, runtime: runtime} when is_pid(runtime) -> [runtime]
          _ -> []
        end
      end)

    explicit =
      case Keyword.get(opts, :collaboration_input) do
        %{runtime: runtime} -> [runtime]
        _ -> []
      end

    Enum.uniq(discovered ++ explicit)
  end

  defp bind_inputs(s) do
    explicit = Keyword.get(s.opts, :collaboration_input)

    Enum.reduce(s.input_runtimes, s, fn runtime, next ->
      if is_map(explicit) and explicit.runtime == runtime do
        next
      else
        identity = input_identity(next)
        send(runtime, {:codex_bind_input, self(), identity})

        timer =
          Process.send_after(self(), {:codex_input_binding_timeout, runtime, identity}, 5_000)

        put_in(next, [:input_binding_pending, runtime], %{identity: identity, timer: timer})
      end
    end)
  end

  defp fail_input_binding(s, runtime, identity, error) do
    case s.input_binding_pending[runtime] do
      %{identity: ^identity, timer: timer} ->
        Process.cancel_timer(timer)
        next = Enum.reduce(s.callers, s, &reply(&2, &1, {:error, error}))

        %{
          next
          | input_binding_pending: Map.delete(next.input_binding_pending, runtime),
            phase: :recovery_required,
            last_error: error,
            jobs: :queue.new()
        }

      _ ->
        s
    end
  end

  defp input_activity(s, activity) do
    Enum.each(
      s.input_runtimes,
      &send(&1, {:codex_input_activity, self(), input_identity(s), activity})
    )

    :ok
  end

  defp now, do: System.system_time(:millisecond)

  defp id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp prepare_nested_tool(
         %{
           effect: %{token: token, role: {:tool, outer, _rest, catalog}},
           nested: nil,
           nested_admission: nil,
           preparation: nil
         },
         token,
         request
       )
       when is_map(request) do
    name = Map.get(request, :tool_name)

    arguments =
      if Map.get(request, :input_kind) == :custom,
        do: Map.get(request, :raw_input),
        else: Map.get(request, :arguments)

    with :ok <- nested_name(name, outer.tool_name),
         {:ok, descriptor} <- ToolRegistry.lookup(catalog.registry, name),
         :ok <- nested_approval(descriptor),
         invocation =
           outer
           |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :turn_id])
           |> Map.merge(%{
             invocation_id: id("nested_invocation"),
             tool_call_id: id("nested_call"),
             tool_name: name,
             tool_revision: descriptor.tool_revision,
             catalog_revision: catalog.revision,
             arguments: arguments
           })
           |> Map.merge(Map.take(descriptor, [:collaboration_binding])) do
      {:ok, invocation, descriptor, catalog}
    end
  end

  defp prepare_nested_tool(%{nested: nested}, _token, _request) when not is_nil(nested),
    do: {:error, Error.new(:resource_conflict, "a nested tool call is already active")}

  defp prepare_nested_tool(%{nested_admission: admission}, _token, _request)
       when not is_nil(admission),
       do: {:error, Error.new(:resource_conflict, "a nested tool call is awaiting admission")}

  defp prepare_nested_tool(_s, _token, _request),
    do: {:error, Error.new(:resource_conflict, "stale nested tool request")}

  defp outer_invocation(_invocation, %{effect: %{role: {:tool, outer, _, _}}}), do: outer
  defp outer_invocation(invocation, _s), do: invocation

  defp nested_name(name, outer_name) when is_binary(name) and name != "" do
    if name == outer_name,
      do: {:error, Error.new(:resource_conflict, "code mode cannot invoke itself")},
      else: :ok
  end

  defp nested_name(_, _), do: {:error, Error.new(:validation, "nested tool name is required")}

  defp nested_approval(%{safety: %{requires_approval: true}}),
    do: {:error, Error.new(:approval_required, "nested tool requires interactive approval")}

  defp nested_approval(_descriptor), do: :ok

  defp normalize_nested_result({:ok, [result]}), do: {:ok, result}
  defp normalize_nested_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_nested_result(other),
    do:
      {:error,
       Error.new(:malformed_result, "nested execution returned invalid data", cause: other)}

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments)) |> Base.encode16(case: :lower)
end
