defmodule Backplane.AgentRuntime.Conversation do
  use GenServer

  alias Backplane.AgentRuntime.{
    Budget,
    Error,
    Execution,
    InputSchema,
    Policy,
    ToolCatalog,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.Kernel, as: RunKernel

  @default_output_limit 1_048_576

  @moduledoc """
  Single authoritative owner of a bounded embedded conversation.

  Drives lazy provider streams and sequential authorized tools without a second
  ExecutionController. All effect intents use Execution.commit/5. Queued inputs,
  messages, interaction state and turn outcomes use kernel checkpoints before
  acknowledgement. Incremental events are transient; terminal events follow
  commit. Subscribers receive `{:agent_runtime, run_id, event}`.

  One root run can contain a prompt and queued follow-up turns. It shares one
  finite work budget and absolute deadline. Once settled, the host starts a new
  run with its canonical messages. Host sessions and Protocol V1 remain outside
  this process. `:run` restores a committed record for inspection only: any
  nonterminal restored run enters recovery_required and dispatches nothing.
  The host must reconcile uncertain effects and fence the previous incarnation
  before admitting replacement work. See PERSISTENCE.md and EMBEDDING.md.
  """

  def start_link(opts) do
    with {:ok, opts} <- admit_initial_catalog(opts),
         {:ok, _} <- Execution.validate_limits(opts),
         {:ok, _} <- Budget.new(%{work: Keyword.get(opts, :work, 100)}) do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    end
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
      steering: [],
      follow_up: [],
      turn_id: nil,
      turns: [],
      pending_interaction: nil,
      queue_status: :active,
      usage: []
    }

    fresh = %{
      run_id: Keyword.fetch!(opts, :run_id),
      incarnation: Keyword.get(opts, :incarnation, 1),
      expected_revision: 0,
      state: :queued,
      admitted: false,
      context: %{conversation: conversation},
      children: [],
      deadline: now() + limits.run,
      execution_budget: budget
    }

    run = Keyword.get(opts, :run, fresh)
    restored? = Keyword.has_key?(opts, :run)

    phase =
      if restored?,
        do: if(RunKernel.terminal?(run.state), do: :terminal, else: :recovery_required),
        else: :idle

    timer = if restored?, do: nil, else: Process.send_after(self(), :deadline, limits.run)

    catalog = ToolCatalog.initial(opts)

    state = %{
      opts: opts,
      run: run,
      conversation: get_in(run, [:context, :conversation]) || conversation,
      phase: phase,
      supervisor: sup,
      limits: limits,
      commit: nil,
      effect: nil,
      jobs: :queue.new(),
      interaction: nil,
      stopping: nil,
      cleanup_due: nil,
      timer: timer,
      callers: [],
      admission: nil,
      last_error: nil,
      bytes: 0,
      catalog: catalog,
      pending_catalog: nil,
      catalog_receipts: []
    }

    {:ok, state}
  end

  @impl true
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
           catalog_publication(s.pending_catalog && s.pending_catalog.catalog, :staged)
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

  def handle_call(:cancel, _from, s), do: {:reply, :ok, stop(s, :cancelled)}

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

  def handle_call({:resolve, id, value}, from, s),
    do: {:noreply, enqueue(%{s | callers: [from | s.callers]}, {:resolve, id, value, from})}

  def handle_call({:interact, token, request}, from, s) do
    if current_effect?(s, token) and is_nil(s.interaction) and is_map(request) do
      {:noreply, enqueue(s, {:interact, token, request, from})}
    else
      {:reply, {:error, Error.new(:resource_conflict, "stale or overlapping interaction")}, s}
    end
  end

  def handle_call({:chunk, token, event}, _from, s) do
    if current_effect?(s, token) and is_map(event) do
      bytes = s.bytes + :erlang.external_size(event)
      limit = output_limit(s.opts)

      if bytes <= limit do
        emit(s, event)
        {:reply, :ok, %{s | bytes: bytes}}
      else
        {:reply,
         {:error,
          Error.new(:resource_conflict, "provider output limit exceeded",
            details: %{limit: limit, size: bytes, scope: :provider_response}
          )}, s}
      end
    else
      {:reply, {:error, Error.new(:resource_conflict, "stale stream")}, s}
    end
  end

  @impl true
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
              entry.next.(%{s | stopping: nil}, prepared)

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
    {:noreply, enqueue(%{s | effect: nil}, {:effect_result, entry.role, result})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    error = Error.new(:execution_failure, "worker exited", cause: inspect(reason))

    cond do
      s.commit && s.commit.task.ref == ref ->
        {:noreply, storage_failed(%{s | commit: nil}, error)}

      s.effect && s.effect.task.ref == ref ->
        Process.cancel_timer(s.effect.timer)
        {:noreply, stop(%{s | effect: nil, last_error: error}, :uncertain)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info({:timeout, ref}, s) do
    cond do
      s.commit && s.commit.task.ref == ref ->
        kill_task(s.commit)

        {:noreply,
         storage_failed(
           %{s | commit: nil},
           Error.new(:timeout, "commit acknowledgement timed out")
         )}

      s.effect && s.effect.task.ref == ref ->
        {:noreply, stop(s, :deadline_exceeded)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(:deadline, s) do
    if s.phase in [:terminal, :storage_failed, :recovery_required],
      do: {:noreply, s},
      else: {:noreply, stop(s, :deadline_exceeded)}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    if s.effect, do: kill_task(s.effect)
    if s.commit, do: kill_task(s.commit)
    if Process.alive?(s.supervisor), do: Supervisor.stop(s.supervisor)
  end

  defp enqueue(s, job), do: drive(%{s | jobs: :queue.in(job, s.jobs)})
  defp drive(%{commit: commit} = s) when not is_nil(commit), do: s
  defp drive(%{stopping: stopping} = s) when not is_nil(stopping), do: advance_stop(s)

  defp drive(s) do
    case :queue.out(s.jobs) do
      {:empty, _} -> s
      {{:value, job}, jobs} -> s |> Map.put(:jobs, jobs) |> process(job) |> drive()
    end
  end

  defp process(%{phase: phase} = s, {:input, _, _, from})
       when phase in [:terminal, :storage_failed, :recovery_required, :cancelling] do
    reply(s, from, {:error, Error.new(:resource_conflict, "run is not accepting input")})
  end

  defp process(s, {:input, mode, content, from}) do
    message = %{role: :user, content: content, id: id("message")}

    if s.phase == :idle do
      s = %{s | phase: :starting}

      commit(s, {:admit, now(), %{state: :running, deadline: s.run.deadline}}, %{}, [], fn s, _ ->
        begin_prompt(%{s | admission: {from, message.id}}, message, :new)
      end)
    else
      mode = if mode == :prompt, do: :follow_up, else: mode
      conversation = Map.update!(s.conversation, mode, &(&1 ++ [message]))

      checkpoint(s, conversation, fn s ->
        reply(s, from, {:ok, %{message_id: message.id}})
      end)
    end
  end

  defp process(s, {:interact, token, request, from}) do
    if current_effect?(s, token) and is_nil(s.interaction) do
      interaction = %{id: id("interaction"), request: request}

      checkpoint(s, %{s.conversation | pending_interaction: interaction}, fn s ->
        emit(s, %{type: :interaction_requested, interaction_id: interaction.id, request: request})
        %{s | interaction: %{id: interaction.id, from: from}, phase: :waiting_interaction}
      end)
    else
      GenServer.reply(from, {:error, Error.new(:resource_conflict, "stale interaction")})
      s
    end
  end

  defp process(s, {:resolve, id, value, from}) do
    case s.interaction do
      %{id: ^id, from: waiter} ->
        checkpoint(s, %{s.conversation | pending_interaction: nil}, fn s ->
          GenServer.reply(waiter, {:ok, value})
          s = reply(s, from, :ok)
          emit(s, %{type: :interaction_resolved, interaction_id: id})
          %{s | interaction: nil, phase: :running}
        end)

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

        checkpoint(s, conversation, fn s ->
          emit(s, %{
            type: :prompt_consumed,
            mode: mode,
            message: message,
            turn_id: conversation.turn_id
          })

          s = acknowledge_admission(s, :ok)
          start_provider(s)
        end)

      {:error, error} ->
        s = acknowledge_admission(s, {:error, error})
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

        input =
          Map.merge(identity, %{
            final?: false,
            result: response,
            context: Map.put(s.run.context, :conversation, conversation)
          })

        commit(s, {:provider_completed, now(), input}, %{}, [], fn s, _ ->
          s = %{s | conversation: conversation}
          emit(s, response.terminal)
          begin_tools(s, response.tools, catalog)
        end)

      {:error, error} ->
        input = Map.merge(identity, %{final?: false, result: %{error: error}})

        commit(s, {:provider_completed, now(), input}, %{}, [], fn s, _ ->
          emit(s, %{type: :response_failed, error: error})
          finish_turn(%{s | last_error: error}, :failed)
        end)
    end
  end

  defp process(s, {:effect_result, {:tool, invocation, rest, catalog}, result}) do
    s = discard_failed_catalog(s, invocation, result)
    result = tool_result(result)
    input = Map.put(invocation, :result, result)

    commit(s, {:tool_completed, now(), input}, %{}, [], fn s, _ ->
      append_tool_result(s, invocation, result, rest, catalog)
    end)
  end

  defp process(
         s,
         {:effect_result, {:approval, invocation, descriptor, rest, catalog}, {:ok, decision}}
       ) do
    if decision == :approved do
      approval = %{
        approval_id: id("approval"),
        run_id: s.run.run_id,
        tool_name: invocation.tool_name,
        tool_revision: invocation.tool_revision,
        arguments_digest: digest(invocation.arguments),
        current_time: now(),
        expires_at: s.run.deadline
      }

      decision =
        Map.merge(
          Map.take(approval, [:approval_id, :tool_name, :tool_revision, :arguments_digest]),
          %{decision: :approved, resolver_id: "host"}
        )

      invoke_tool(s, invocation, descriptor, rest, catalog,
        approval: approval,
        approval_decision: decision
      )
    else
      append_tool_result(
        s,
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

  defp process(s, {:effect_result, _, _}), do: fail(s, "invalid adapter result")

  defp begin_prompt(s, message, mode) do
    s = if mode == :new, do: %{s | last_error: nil}, else: s

    start_effect(s, {:prompt, message, mode}, fn context ->
      hook(s, :prompt, [message, context], {:ok, message})
    end)
  end

  defp start_provider(s) do
    catalog = s.catalog
    identity = Map.merge(identity(s), %{step_id: id("step"), attempt_id: id("attempt")})

    request =
      Map.merge(identity, %{
        messages: s.conversation.messages,
        turn_id: s.conversation.turn_id,
        catalog_revision: catalog.revision,
        tools: catalog.tools
      })

    opts = [adapter: Keyword.fetch!(s.opts, :provider)]

    commit(s, {:provider_started, now(), identity}, %{operation: request}, opts, fn s, _ ->
      start_effect(%{s | bytes: 0}, {:provider, identity, catalog}, fn context ->
        stream(s, request, context)
      end)
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
            case terminal_tools(acc.tools, message) do
              {:ok, tools} ->
                usage = if Map.get(event, :usage), do: acc.usage ++ [event.usage], else: acc.usage

                {:halt,
                 {:ok, %{acc | terminal: event, message: message, tools: tools, usage: usage}}}

              {:error, _} = error ->
                {:halt, error}
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
                 :usage_updated
               ] ->
            case context.emit.(event) do
              :ok ->
                case collect(acc, event) do
                  {:ok, acc} -> {:cont, {:ok, acc}}
                  {:error, error} -> {:halt, {:error, error}}
                end

              error ->
                {:halt, error}
            end

          _ ->
            {:halt, {:error, "unsupported normalized provider event"}}
        end
      end)

    case result do
      {:ok, %{terminal: nil}} ->
        {:error, "provider ended without terminal event"}

      {:ok, response} ->
        if :erlang.external_size(response) <= output_limit(s.opts),
          do: {:ok, response},
          else: {:error, "provider result exceeds output limit"}

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

  defp output_limit(opts), do: Keyword.get(opts, :output_limit, @default_output_limit)

  defp collect(acc, %{
         type: :tool_call_completed,
         tool_call: %{id: id, name: name, arguments: args} = tool
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(args) do
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
         {:ok, arguments} <- InputSchema.validate(descriptor.schema, call.arguments),
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
               arguments: arguments
             })
           ),
         {:ok, _} <-
           Policy.authorize_tool(catalog.authority, descriptor, invocation) do
      if descriptor.safety[:requires_approval] do
        start_effect(s, {:approval, invocation, descriptor, rest, catalog}, fn context ->
          context.interact.(%{kind: :permission, operation: invocation})
        end)
      else
        invoke_tool(s, invocation, descriptor, rest, catalog, [])
      end
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

  defp invoke_tool(s, invocation, _descriptor, rest, catalog, approval) do
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
                Map.take(context, [:interact, :emit, :stage_catalog])
              )
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

      [] when tools? ->
        start_provider(s)

      [] ->
        start_effect(s, :stop_hook, fn context ->
          hook(s, :stop, [s.conversation.messages, context], :stop)
        end)
    end
  end

  defp finish_turn(s, outcome) do
    turn = %{turn_id: s.conversation.turn_id, outcome: outcome, error: s.last_error}

    checkpoint(s, %{s.conversation | turns: s.conversation.turns ++ [turn]}, fn s ->
      emit(
        s,
        Map.put(turn, :type, if(outcome == :completed, do: :turn_completed, else: :turn_failed))
      )

      case s.conversation.follow_up do
        [message | rest] ->
          checkpoint(s, %{s.conversation | follow_up: rest}, &begin_prompt(&1, message, :new))

        [] ->
          input = Map.merge(identity(s), %{status: outcome, outcome: turn})

          commit(s, {:finish, now(), input}, %{}, [], fn s, _ ->
            emit(s, %{
              type: if(outcome == :completed, do: :run_completed, else: :run_failed),
              outcome: turn
            })

            %{s | phase: :terminal}
          end)
      end
    end)
  end

  defp fail(s, reason), do: finish_turn(%{s | last_error: reason}, :failed)

  defp checkpoint(s, conversation, next) do
    input = Map.merge(identity(s), %{conversation: conversation})

    commit(s, {:conversation_updated, now(), input}, %{}, [], fn s, _ ->
      next.(%{s | conversation: conversation})
    end)
  end

  defp commit(s, {kind, _, input} = command, meta, extra, next)
       when kind in [:provider_started, :tool_invoked] do
    reservation =
      if kind == :provider_started,
        do: "provider:#{input.attempt_id}",
        else: "tool:#{input.invocation_id}"

    case Budget.reserve(s.run.execution_budget, reservation) do
      {:ok, _, _} -> do_commit(s, command, meta, extra, next)
      {:error, error} -> finish_turn(%{s | last_error: error}, :failed)
    end
  end

  defp commit(s, command, meta, extra, next), do: do_commit(s, command, meta, extra, next)

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

    timer = Process.send_after(self(), {:timeout, task.ref}, timeout)
    %{s | commit: %{task: task, timer: timer, next: next}}
  end

  defp start_effect(s, role, function) do
    owner = self()
    token = make_ref()

    context =
      Keyword.get(s.opts, :provider_context, %{})
      |> Map.put(:interact, fn request ->
        GenServer.call(owner, {:interact, token, request}, :infinity)
      end)
      |> Map.put(:emit, fn event -> GenServer.call(owner, {:chunk, token, event}, :infinity) end)

    context =
      case role do
        {:tool, _, _, _} ->
          Map.put(context, :stage_catalog, fn update ->
            GenServer.call(owner, {:stage_catalog, token, update}, :infinity)
          end)

        _ ->
          context
      end

    task = Task.Supervisor.async_nolink(s.supervisor, fn -> function.(context) end)
    timeout = max(1, min(s.limits.effect, s.run.deadline - now()))
    timer = Process.send_after(self(), {:timeout, task.ref}, timeout)
    %{s | effect: %{task: task, timer: timer, role: role, token: token}, phase: :running}
  end

  defp hook(s, function, args, default) do
    adapter = Keyword.get(s.opts, :hooks)

    if adapter && Code.ensure_loaded?(adapter) &&
         function_exported?(adapter, function, length(args)),
       do: apply(adapter, function, args),
       else: default
  end

  defp stop(s, reason) do
    if s.effect, do: kill_task(s.effect)

    if s.interaction,
      do: GenServer.reply(s.interaction.from, {:error, Error.new(:cancelled, "run cancelled")})

    Enum.each(s.callers, &GenServer.reply(&1, {:error, Error.new(:cancelled, "run stopped")}))
    reject_jobs(s.jobs)

    s = discard_pending_catalog(s)

    s = %{
      s
      | effect: nil,
        interaction: nil,
        jobs: :queue.new(),
        callers: [],
        admission: nil,
        phase: :cancelling,
        cleanup_due: s.cleanup_due || System.monotonic_time(:millisecond) + s.limits.cleanup,
        stopping:
          s.stopping ||
            %{
              reason: reason,
              uncertain:
                map_size(Map.get(s.run, :active_tools, %{})) > 0 or
                  not is_nil(Map.get(s.run, :active_provider))
            }
    }

    if s.commit, do: s, else: advance_stop(s)
  end

  defp advance_stop(%{commit: commit} = s) when not is_nil(commit), do: s

  defp advance_stop(s) do
    cond do
      RunKernel.terminal?(s.run.state) ->
        %{s | stopping: nil, phase: :terminal}

      s.run.state == :running and Map.get(s.conversation, :queue_status) != :suspended ->
        conversation =
          s.conversation
          |> Map.put(:pending_interaction, nil)
          |> Map.put(:queue_status, :suspended)

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
          emit(s, %{type: :run_cancelled, outcome: s.run.outcome, state: s.run.state})
          %{s | phase: :terminal}
        end)

      true ->
        command =
          if s.stopping.reason == :deadline_exceeded, do: :deadline_exceeded, else: :cancel

        commit(s, {command, now()}, %{}, [], fn s, _ -> s end)
    end
  end

  defp storage_failed(s, error) do
    if s.effect, do: kill_task(s.effect)
    Enum.each(s.callers, &GenServer.reply(&1, {:error, error}))
    reject_jobs(s.jobs)
    emit(s, %{type: :storage_failed, error: error, recovery_required: true})

    s = discard_pending_catalog(s)

    %{
      s
      | phase: :storage_failed,
        effect: nil,
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
  defp current_effect?(%{effect: %{token: token}, stopping: nil}, token), do: true
  defp current_effect?(_, _), do: false

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
            invocation_id = s.effect.role |> elem(1) |> Map.fetch!(:invocation_id)

            next = %{
              s
              | pending_catalog: %{
                  catalog: catalog,
                  update: update,
                  owner_invocation_id: invocation_id
                },
                catalog_receipts: remember_receipt(s.catalog_receipts, update, receipt)
            }

            {:ok, receipt, next}
          end
      end
    end
  end

  defp catalog_reconciliation_allowed(_s, nil), do: :ok

  defp catalog_reconciliation_allowed(%{effect: %{token: token}, stopping: nil}, token), do: :ok

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
         %{pending_catalog: %{owner_invocation_id: invocation_id}} = s,
         %{invocation_id: invocation_id},
         _result
       ),
       do: discard_pending_catalog(s)

  defp discard_failed_catalog(s, _invocation, _result), do: s

  defp discard_owned_catalog(
         %{pending_catalog: %{owner_invocation_id: invocation_id}} = s,
         %{invocation_id: invocation_id}
       ),
       do: discard_pending_catalog(s)

  defp discard_owned_catalog(s, _invocation), do: s

  defp discard_pending_catalog(%{pending_catalog: nil} = s), do: s

  defp discard_pending_catalog(%{pending_catalog: pending} = s) do
    receipts =
      Enum.reject(s.catalog_receipts, &(&1.publication_id == pending.catalog.publication_id))

    %{s | pending_catalog: nil, catalog_receipts: receipts}
  end

  defp publish_catalog(%{pending_catalog: nil} = s), do: s

  defp publish_catalog(%{pending_catalog: pending} = s) do
    receipt = ToolCatalog.receipt(pending.catalog, :published)
    emit(s, %{type: :catalog_published, catalog_revision: pending.catalog.revision})

    %{
      s
      | catalog: pending.catalog,
        pending_catalog: nil,
        catalog_receipts: remember_receipt(s.catalog_receipts, pending.update, receipt)
    }
  end

  defp catalog_publication(nil, _status), do: nil
  defp catalog_publication(%{publication_id: nil}, _status), do: nil
  defp catalog_publication(catalog, status), do: ToolCatalog.receipt(catalog, status)

  defp clear_task(entry) do
    Process.demonitor(entry.task.ref, [:flush])
    Process.cancel_timer(entry.timer)
  end

  defp kill_task(entry) do
    clear_task(entry)
    Process.exit(entry.task.pid, :kill)
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
  defp now, do: System.system_time(:millisecond)

  defp id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments)) |> Base.encode16(case: :lower)
end
