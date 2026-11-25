defmodule Backplane.AgentRuntime.Codex.MultiAgentMailboxTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Session}

  @tools ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, context.role, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule RealtimeFixture do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, %{connection: connection, test: test}) do
      generation = Agent.get(connection, & &1.generation)
      key = {generation, "response-" <> request.attempt_id}

      delivered =
        Agent.get_and_update(connection, fn state ->
          {messages, seen} = Enum.map_reduce(request.messages, state.seen, &project/2)
          {Enum.reject(messages, &is_nil/1), %{state | seen: seen}}
        end)

      send(test, {:voice_attempt, request, key, delivered, self()})

      Stream.resource(
        fn -> key end,
        fn key ->
          receive do
            {:voice_events, ^key, events} -> {events, key}
            {:voice_events, _stale, _events} -> {[], key}
          end
        end,
        fn _ -> :ok end
      )
    end

    @impl true
    def prepare_tool(invocation, context) do
      {:ok, _} =
        context.append_feedback.(%{
          id: "feedback:" <> invocation.invocation_id,
          text: "delegation accepted by host policy",
          source: "test host",
          stage: "prepare"
        })

      :allow
    end

    defp project(
           %{role: :user, id: id, content: [%{type: :committed_audio, item_id: item}]},
           seen
         ),
         do: deliver({:message, id}, {:audio_reference, item}, seen)

    defp project(%{role: :user, host_feedback: %{"id" => id}, content: text}, seen),
      do: deliver({:feedback, id}, {:text, text}, seen)

    defp project(%{role: :user, id: id, content: text}, seen),
      do: deliver({:message, id}, {:text, text}, seen)

    defp project(%{role: :tool, invocation_id: id, tool_call_id: call_id, result: result}, seen),
      do: deliver({:tool_result, id}, {:function_call_output, call_id, result}, seen)

    defp project(_message, seen), do: {nil, seen}

    defp deliver(id, item, seen) do
      if MapSet.member?(seen, id), do: {nil, seen}, else: {item, MapSet.put(seen, id)}
    end
  end

  defmodule GateStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(%{table: table, gates: gates}, run, meta) do
      case meta.command do
        {:finish, _, %{status: :completed}} ->
          hold(gates, :hold_finish)

        {:conversation_updated, _,
         %{conversation: %{mailbox: [%{collaboration: %{kind: :result}} | _]}}} ->
          hold(gates, :hold_result)

        _ ->
          :ok
      end

      case :ets.take(gates, :fail_next) do
        [] -> EphemeralStore.store(table, run, meta)
        [_] -> {:error, Error.new(:execution_failure, "mailbox checkpoint rejected")}
      end
    end

    defp hold(gates, key) do
      case :ets.take(gates, key) do
        [{^key, test}] ->
          send(test, {key, self()})

          receive do
            :release_checkpoint -> :ok
          end

        [] ->
          :ok
      end
    end
  end

  defp start_runtime(options \\ []) do
    test_pid = self()
    catalog = :ets.new(:mailbox_catalog, [:set, :public])

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: authority("root"),
         max_concurrent_threads_per_session: Keyword.get(options, :max_threads, 4),
         min_wait_timeout_ms: 0,
         child_options: fn request, run_id, context ->
           with :ok <- resolve_child_target(options[:voice_child], request, test_pid) do
             [{:profile, profile}] = :ets.lookup(catalog, :profile)
             {:ok, store} = EphemeralStore.new(1)
             send(test_pid, {:child_options, run_id, context})

             {:ok,
              [
                run_id: run_id,
                store: Keyword.get(options, :store, EphemeralStore),
                context: store_context(store, options),
                provider: Provider,
                provider_context: %{test: test_pid, role: :child},
                registry: profile.registry,
                tools: profile.tools,
                authority: authority(run_id),
                schema_admission: :strict,
                work: 30,
                run_timeout: :infinity
              ]}
           end
         end}
      )

    assert {:ok, profile} =
             Codex.profile(
               :collaboration_v2,
               %{collaboration_runtime: runtime},
               authority("root"),
               tools: @tools
             )

    :ets.insert(catalog, {:profile, profile})
    runtime
  end

  defp resolve_child_target(nil, _request, _test), do: :ok

  defp resolve_child_target(
         true,
         %{options: %{"agent_type" => "standard"} = opts} = request,
         test
       ) do
    if opts["fork_turns"] in [nil, "none"] do
      send(test, {:voice_child_target, request})
      :ok
    else
      {:error, Error.new(:validation, "voice child history projection is unavailable")}
    end
  end

  defp resolve_child_target(true, _request, _test),
    do: {:error, Error.new(:validation, "expected an explicit standard child target")}

  defp authority(run_id) do
    %{
      caller: "host",
      run_id: run_id,
      grants: @tools,
      tool_revisions: Map.new(@tools, &{&1, 1})
    }
  end

  defp store_context(table, options) do
    if options[:gates], do: %{table: table, gates: options[:gates]}, else: table
  end

  defp attach_root(runtime, options \\ []) do
    run_id = Keyword.get(options, :run_id, "root")

    session =
      Keyword.get_lazy(options, :session, fn ->
        start_supervised!({Session, owner_pid: self(), cleanup_timeout: 1_000})
      end)

    assert {:ok, binding} = Session.bind(session, authority(run_id), incarnation: 1)

    assert {:ok, profile} =
             Codex.profile(
               :collaboration_v2,
               %{
                 collaboration_runtime: runtime,
                 session_binding: binding,
                 caller: %{run_id: run_id}
               },
               authority(run_id),
               tools: @tools
             )

    {:ok, store} = EphemeralStore.new(1)

    root =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         incarnation: binding.run_incarnation,
         session_binding: binding,
         store: Keyword.get(options, :store, EphemeralStore),
         context: store_context(store, options),
         provider: Keyword.get(options, :provider, Provider),
         provider_context: Keyword.get(options, :provider_context, %{test: self(), role: :root}),
         hooks: options[:hooks],
         subscriber: options[:subscriber],
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         work: 50,
         run_timeout: :infinity,
         effect_timeout: 2_000,
         cleanup_timeout: 1_000}
      )

    %{pid: root, binding: binding, session: session}
  end

  defp start_root(root) do
    assert {:ok, _} = Conversation.prompt(root.pid, "coordinate")
    assert_receive {:provider, :root, _, provider}, 1_000
    provider
  end

  defp tool(provider, name, arguments) do
    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "call-" <> Integer.to_string(System.unique_integer([:positive])),
            name: name,
            arguments: arguments
          }
        },
        done("using " <> name)
      ]
    })
  end

  defp tool_result(request, name) do
    request.messages
    |> Enum.filter(&(&1[:role] == :tool and &1[:name] == name))
    |> List.last()
    |> Map.fetch!(:result)
  end

  defp mailbox_message(request, text) do
    Enum.find(request.messages, fn message ->
      message[:role] in [:user, "user"] and contains_text?(message[:content], text)
    end) || flunk("queued message missing from provider boundary: #{inspect(request.messages)}")
  end

  defp contains_text?(content, text) when is_binary(content), do: String.contains?(content, text)
  defp contains_text?(content, text), do: String.contains?(inspect(content), text)

  defp wait_registered(runtime) do
    assert eventually(fn -> map_size(:sys.get_state(runtime).waiters) == 1 end)
  end

  defp call(runtime, tool, arguments, run_id \\ "root") do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: :v2},
      run_id: run_id,
      tool_name: tool,
      arguments: arguments
    })
  end

  defp spawn_child(runtime, name \\ "worker") do
    assert {:ok, %{task_name: canonical}} =
             call(runtime, "spawn_agent", %{"task_name" => name, "message" => "work"})

    assert_receive {:child_options, run_id, _}, 1_000
    assert_receive {:provider, :child, request, provider}, 1_000
    assert request.run_id == run_id
    %{name: canonical, run_id: run_id, provider: provider}
  end

  defp finish(child, content \\ "done") do
    send(child.provider, {:events, [done(content)]})
  end

  defp done(content) do
    %{type: :response_completed, message: %{role: :assistant, content: content}}
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end

  defp completed?(runtime, name) do
    {:ok, snapshot} = MultiAgent.snapshot(runtime)
    Enum.any?(snapshot.agents, &(&1.name == name and &1.status == :completed))
  end

  defp result_delivery(runtime, name) do
    {:ok, snapshot} = MultiAgent.snapshot(runtime)
    snapshot.agents |> Enum.find(&(&1.name == name)) |> Map.get(:result_delivery)
  end

  test "finite voice attempts keep standard child work and consume new history on the next response" do
    runtime = start_runtime(voice_child: true)
    connection = start_supervised!({Agent, fn -> %{generation: 1, seen: MapSet.new()} end})

    root =
      attach_root(runtime,
        provider: RealtimeFixture,
        provider_context: %{test: self(), connection: connection},
        hooks: RealtimeFixture,
        subscriber: self()
      )

    audio = [%{type: :committed_audio, item_id: "audio-1", connection_generation: 1}]
    assert {:ok, _} = Conversation.prompt(root.pid, audio)
    assert_receive {:voice_attempt, _, {1, _} = first, [{:audio_reference, "audio-1"}], worker}

    call = %{
      type: :tool_call,
      id: "native-call-1",
      name: "spawn_agent",
      arguments: %{
        "task_name" => "standard_child",
        "agent_type" => "standard",
        "fork_turns" => "none",
        "message" => "Summarize the confirmed text."
      }
    }

    send(worker, {
      :voice_events,
      first,
      [%{type: :tool_call_completed, tool_call: call}, done([call])]
    })

    assert_receive {:voice_child_target, %{options: %{"agent_type" => "standard"}}}

    assert_receive {:provider, :child, child_request, child}, 1_000
    assert [%{role: :user, content: "Summarize the confirmed text."}] = child_request.messages

    assert_receive {:voice_attempt, continuation, {1, _} = second, delivered, worker}, 1_000
    assert first != second

    assert [
             {:function_call_output, "native-call-1", %{task_name: "/root/standard_child"}},
             {:text, feedback}
           ] = delivered

    assert feedback =~ "delegation accepted by host policy"
    assert Enum.count(continuation.messages, &match?(%{role: :tool}, &1)) == 1

    interrupted = %{type: :response_interrupted, reason: "barge_in"}
    send(worker, {:voice_events, second, [interrupted, done("late completion")]})
    assert_receive {:agent_runtime, "root", %{type: :response_interrupted}}

    assert {:ok, %{agents: [%{name: "/root/standard_child", status: :running}]}} =
             MultiAgent.snapshot(runtime)

    # Media has been closed by the host. The child result queues without an
    # implicit provider start, and the host explicitly opens a new generation.
    Agent.update(connection, &%{&1 | generation: nil})
    send(child, {:events, [done("confirmed child result")]})

    assert eventually(fn ->
             match?(%{status: :accepted}, result_delivery(runtime, "/root/standard_child"))
           end)

    refute_receive {:voice_attempt, _, _, _, _}, 30

    Agent.update(connection, &%{&1 | generation: 2})
    assert {:ok, _} = Conversation.prompt(root.pid, "explicit next call")
    assert_receive {:voice_attempt, resumed, {2, _} = third, delivered, worker}, 1_000
    assert [{:text, "explicit next call"}, {:text, child_final}] = delivered
    assert child_final =~ "confirmed child result"
    result_id = mailbox_message(resumed, "confirmed child result").id

    send(worker, {:voice_events, second, [interrupted]})
    assert {:ok, _} = Conversation.follow_up(root.pid, "another input")
    Agent.update(connection, &Map.put(&1, :playing, third))

    send(
      worker,
      {:voice_events, third, [done("generated while playback continues"), interrupted]}
    )

    assert_receive {:agent_runtime, "root",
                    %{
                      type: :response_completed,
                      message: %{content: "generated while playback continues"}
                    }}

    # A playback-only stop does not report a provider interruption to this
    # already-completed attempt. The next response only receives the new input.
    assert ^third = Agent.get_and_update(connection, &Map.pop(&1, :playing))
    assert_receive {:voice_attempt, final, fourth, [{:text, "another input"}], worker}
    assert Enum.count(final.messages, &(&1[:id] == result_id)) == 1

    assert Conversation.status(root.pid).run.last_provider_result.terminal.type ==
             :response_completed

    refute_receive {:agent_runtime, "root", %{type: :response_interrupted}}, 20

    send(worker, {:voice_events, fourth, [done("last response")]})
    assert_receive {:agent_runtime, "root", %{type: :run_completed}}
  end

  test "running send_message queues without steering or implicitly requesting another provider" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    pid = :sys.get_state(runtime).agents[child.name].pid

    assert {:ok, %{accepted: true}} =
             call(runtime, "send_message", %{"target" => child.name, "message" => "queued only"})

    assert Conversation.status(pid).conversation.steering == []
    finish(child)
    assert eventually(fn -> completed?(runtime, child.name) end)
    refute_receive {:provider, :child, _, _}, 30
  end

  test "idle send_message accepts queued text and followup explicitly activates it" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    finish(child)
    assert eventually(fn -> completed?(runtime, child.name) end)

    assert {:ok, %{accepted: true}} =
             call(runtime, "send_message", %{"target" => child.name, "message" => "idle mailbox"})

    refute_receive {:provider, :child, _, _}, 30

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "activate"})

    assert_receive {:provider, :child, request, _}, 1_000
    assert mailbox_message(request, "idle mailbox")
    assert Enum.any?(request.messages, &(&1[:content] == "activate"))
  end

  test "wait timeout leaves the independently running child and provider intact" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    pid = :sys.get_state(runtime).agents[child.name].pid

    assert {:ok, %{message: "Wait timed out.", timed_out: true}} =
             call(runtime, "wait_agent", %{"timeout_ms" => 10})

    assert Process.alive?(child.provider)
    assert Conversation.status(pid).run.state == :running
    finish(child)
    assert eventually(fn -> completed?(runtime, child.name) end)
  end

  test "queue-only send rejects interrupted recovery targets rather than acknowledging loss" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    pid = :sys.get_state(runtime).agents[child.name].pid
    Process.exit(pid, :kill)

    assert eventually(fn ->
             {:ok, snapshot} = MultiAgent.snapshot(runtime)

             Enum.any?(
               snapshot.agents,
               &(&1.name == child.name and &1.status == :unknown_outcome)
             )
           end)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "send_message", %{"target" => child.name, "message" => "unsafe"})

    refute_receive {:provider, :child, _, _}, 30
  end

  test "a child model sends to its idle root without triggering a root provider" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    tool(child.provider, "send_message", %{"target" => "/root", "message" => "child report"})

    assert_receive {:provider, :child, request, _}, 1_000
    assert %{accepted: true} = tool_result(request, "send_message")
    refute_receive {:provider, :root, _, _}, 30

    assert {:ok, _} = Conversation.prompt(root.pid, "read queued report")
    assert_receive {:provider, :root, root_request, _}, 1_000
    message = mailbox_message(root_request, "child report")

    assert %{
             kind: :message,
             source_name: source_name,
             source_run_id: source_run,
             source_agent_id: source_id,
             source_incarnation: 1
           } = message.collaboration

    assert source_name == child.name
    assert source_run == child.run_id
    assert is_binary(source_id)
  end

  test "terminal child result reaches the parent input boundary and wakes its model wait" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    finish(child, "terminal result for parent")

    assert_receive {:provider, :root, request, _}, 1_000
    assert %{message: "Wait completed.", timed_out: false} = tool_result(request, "wait_agent")
    result_message = mailbox_message(request, "terminal result for parent")

    assert %{
             kind: :result,
             source_name: source_name,
             source_run_id: source_run,
             source_agent_id: source_id,
             source_incarnation: 1,
             result_id: result_id
           } = result_message.collaboration

    assert source_name == child.name
    assert source_run == child.run_id
    assert is_binary(source_id)
    assert is_binary(result_id)
    refute result_id == ""
    assert result_message.id == result_id

    assert eventually(fn ->
             match?(
               %{status: :accepted, result_id: ^result_id},
               result_delivery(runtime, child.name)
             )
           end)
  end

  test "new root steer wakes a blocked model wait distinctly and leaves its child running" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    assert {:ok, _} = Conversation.steer(root.pid, "new root direction")

    assert_receive {:provider, :root, request, _}, 300

    assert %{message: "Wait interrupted by new input.", timed_out: false} =
             tool_result(request, "wait_agent")

    assert mailbox_message(request, "new root direction")
    assert Process.alive?(child.provider)
    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    assert Enum.any?(snapshot.agents, &(&1.name == child.name and &1.status == :running))
  end

  test "a queued child message wakes the root wait through mailbox activity" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    tool(child.provider, "send_message", %{"target" => "/root", "message" => "wake mailbox"})

    assert_receive {:provider, :root, request, _}, 1_000
    assert %{message: "Wait completed.", timed_out: false} = tool_result(request, "wait_agent")
    assert mailbox_message(request, "wake mailbox")
    assert_receive {:provider, :child, child_request, _}, 1_000
    assert %{accepted: true} = tool_result(child_request, "send_message")
  end

  test "already pending steer outranks mailbox activity before a model wait subscribes" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    assert {:ok, _} = Conversation.steer(root.pid, "priority steer")

    tool(child.provider, "send_message", %{"target" => "/root", "message" => "pending mailbox"})
    assert_receive {:provider, :child, child_request, _}, 1_000
    assert %{accepted: true} = tool_result(child_request, "send_message")
    tool(provider, "wait_agent", %{"timeout_ms" => 500})

    assert_receive {:provider, :root, request, _}, 300

    assert %{message: "Wait interrupted by new input.", timed_out: false} =
             tool_result(request, "wait_agent")

    assert mailbox_message(request, "priority steer")
    assert mailbox_message(request, "pending mailbox")
  end

  test "repeated terminal notifications and stale child runs do not duplicate parent results" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    finish(child, "one terminal result")
    assert_receive {:provider, :root, first_request, provider}, 1_000
    first = mailbox_message(first_request, "one terminal result")

    event = %{
      type: :run_completed,
      run_id: child.run_id,
      incarnation: 1,
      outcome: %{outcome: :completed}
    }

    send(runtime, {:agent_runtime, child.run_id, event})
    assert {:ok, _} = MultiAgent.snapshot(runtime)
    tool(provider, "followup_task", %{"target" => child.name, "message" => "second task"})
    assert_receive {:child_options, next_run, _}, 1_000
    assert_receive {:provider, :child, child_request, _}, 1_000
    assert child_request.run_id == next_run
    refute next_run == child.run_id
    assert_receive {:provider, :root, _, provider}, 1_000

    send(runtime, {:agent_runtime, child.run_id, event})
    assert {:ok, _} = MultiAgent.snapshot(runtime)
    tool(provider, "wait_agent", %{"timeout_ms" => 10})
    assert_receive {:provider, :root, final_request, _}, 1_000

    assert %{message: "Wait timed out.", timed_out: true} =
             tool_result(final_request, "wait_agent")

    results =
      Enum.filter(final_request.messages, fn message ->
        message[:role] in [:user, "user"] and
          contains_text?(message[:content], "one terminal result")
      end)

    assert results == [first]
  end

  test "closing the owning Session fences child messages to the former root" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    assert {:ok, _} = Session.close(root.session)

    assert {:error, %Error{class: :forbidden}} =
             call(
               runtime,
               "send_message",
               %{"target" => "/root", "message" => "stale"},
               child.run_id
             )

    refute_receive {:provider, :root, _, _}, 30
    assert Session.status(root.session).phase == :closed
  end

  test "active mailbox checkpoint failure never returns an accepted message receipt" do
    gates = :ets.new(:mailbox_failure, [:set, :public])
    runtime = start_runtime(store: GateStore, gates: gates)
    child = spawn_child(runtime)
    :ets.insert(gates, {:fail_next, true})

    assert {:error, %Error{}} =
             call(runtime, "send_message", %{"target" => child.name, "message" => "rejected mail"})

    refute_receive {:provider, :child, _, _}, 30
  end

  test "idle mailbox survives safe process unloading and is consumed once on explicit followup" do
    runtime = start_runtime(max_threads: 2)
    child = spawn_child(runtime)
    finish(child)
    assert eventually(fn -> completed?(runtime, child.name) end)

    assert {:ok, %{accepted: true}} =
             call(runtime, "send_message", %{
               "target" => child.name,
               "message" => "survive unload"
             })

    sibling = spawn_child(runtime, "sibling")
    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    assert Enum.any?(snapshot.agents, &(&1.name == child.name and &1.resident == false))
    finish(sibling)
    assert eventually(fn -> completed?(runtime, sibling.name) end)

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "first resume"})

    assert_receive {:provider, :child, first_request, provider}, 1_000
    queued = mailbox_message(first_request, "survive unload")
    send(provider, {:events, [done("first resumed result")]})
    assert eventually(fn -> completed?(runtime, child.name) end)

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{
               "target" => child.name,
               "message" => "second resume"
             })

    assert_receive {:provider, :child, second_request, _}, 1_000
    assert Enum.count(second_request.messages, &(&1[:id] == queued.id)) == 1
  end

  test "mail for a detached root survives fresh binding while stale root authority is rejected" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    send(provider, {:events, [done("root turn ended")]})
    assert eventually(fn -> Session.status(root.session).phase == :idle end)

    tool(child.provider, "send_message", %{"target" => "/root", "message" => "between root turns"})

    assert_receive {:provider, :child, child_request, _}, 1_000
    assert %{accepted: true} = tool_result(child_request, "send_message")
    refute_receive {:provider, :root, _, _}, 30

    next = attach_root(runtime, session: root.session, run_id: "root-next")
    assert {:ok, _} = Conversation.prompt(next.pid, "next root turn")
    assert_receive {:provider, :root, request, _}, 1_000
    assert request.run_id == "root-next"
    assert mailbox_message(request, "between root turns")

    assert {:error, %Error{class: :forbidden}} =
             MultiAgent.call(%{
               backend_context: %{runtime: runtime, profile: :v2, resource_owner: root.binding},
               run_id: root.binding.run_id,
               incarnation: root.binding.run_incarnation,
               tool_name: "send_message",
               arguments: %{"target" => child.name, "message" => "old binding"}
             })
  end

  test "mail queued during a final root response transfers to its next session binding" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)

    {:ok, owner} =
      Session.validate(root.binding, %{
        run_id: root.binding.run_id,
        incarnation: root.binding.run_incarnation
      })

    sender = %{
      run_id: root.binding.run_id,
      incarnation: root.binding.run_incarnation,
      caller: "host",
      backend_context: %{resource_owner: owner}
    }

    {:ok, snapshot} = MultiAgent.snapshot(runtime)

    recipient =
      %{
        manager_id: snapshot.manager_id,
        agent_id: snapshot.root.agent_id,
        run_id: root.binding.run_id,
        incarnation: root.binding.run_incarnation
      }

    assert {:ok, %{status: :accepted, acceptance: :checkpointed}} =
             MultiAgent.notify_active(runtime, sender, recipient, %{
               id: "missed-root-notice",
               text: "unconsumed root notice"
             })

    tool(child.provider, "send_message", %{"target" => "/root", "message" => "retain after final"})

    assert_receive {:provider, :child, child_request, _}, 1_000
    assert %{accepted: true} = tool_result(child_request, "send_message")
    send(provider, {:events, [done("root final")]})
    assert eventually(fn -> Session.status(root.session).phase == :idle end)
    refute_receive {:provider, :root, _, _}, 30

    next = attach_root(runtime, session: root.session, run_id: "root-next")
    assert {:ok, _} = Conversation.prompt(next.pid, "resume root")
    assert_receive {:provider, :root, request, _}, 1_000
    assert mailbox_message(request, "retain after final")
    refute Enum.any?(request.messages, &(&1[:content] == "unconsumed root notice"))
  end

  test "a child result sent to a settling root survives its Session handoff" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    gates = :ets.new(:root_finish, [:set, :public])
    root = attach_root(runtime, store: GateStore, gates: gates)
    provider = start_root(root)

    :ets.insert(gates, {:hold_finish, self()})
    send(provider, {:events, [done("root final")]})
    assert_receive {:hold_finish, commit}, 1_000
    assert Session.status(root.session).phase == :detaching

    finish(child, "result during root handoff")

    assert eventually(fn ->
             :queue.to_list(:sys.get_state(root.pid).jobs)
             |> Enum.any?(&match?({:mailbox, %{collaboration: %{kind: :result}}, _}, &1))
           end)

    assert %{status: :pending, result_id: result_id} = result_delivery(runtime, child.name)
    send(commit, :release_checkpoint)
    assert eventually(fn -> Session.status(root.session).phase == :idle end)

    assert eventually(fn ->
             match?(
               %{status: :accepted, result_id: ^result_id},
               result_delivery(runtime, child.name)
             )
           end)

    next = attach_root(runtime, session: root.session, run_id: "root-next")
    refute_receive {:provider, :root, _, _}, 30
    assert {:ok, _} = Conversation.prompt(next.pid, "resume root")
    assert_receive {:provider, :root, request, _}, 1_000

    assert [%{collaboration: %{result_id: ^result_id, source_run_id: source}} = message] =
             Enum.filter(request.messages, &(&1[:id] == result_id))

    assert source == child.run_id
    assert message.content =~ "result during root handoff"
  end

  test "handoff does not replay a consumed result with an outstanding delivery acknowledgement" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    gates = :ets.new(:result_checkpoint, [:set, :public])
    root = attach_root(runtime, store: GateStore, gates: gates)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 1_000})
    wait_registered(runtime)

    :ets.insert(gates, {:hold_result, self()})
    finish(child, "consumed by the settling root")
    assert_receive {:hold_result, commit}, 1_000

    assert [%{worker: worker, source: %{result_id: result_id}}] =
             Map.values(:sys.get_state(runtime).deliveries)

    assert :erlang.suspend_process(worker)
    send(commit, :release_checkpoint)

    assert_receive {:provider, :root, request, provider}, 1_000
    assert %{id: ^result_id} = mailbox_message(request, "consumed by the settling root")
    assert %{status: :pending, result_id: ^result_id} = result_delivery(runtime, child.name)

    send(provider, {:events, [done("root final")]})
    assert eventually(fn -> Session.status(root.session).phase == :idle end)

    assert %{status: :accepted, result_id: ^result_id, acceptance: :checkpointed} =
             result_delivery(runtime, child.name)

    next = attach_root(runtime, session: root.session, run_id: "root-next")
    assert {:ok, _} = Conversation.prompt(next.pid, "resume root")
    assert_receive {:provider, :root, request, _}, 1_000
    refute Enum.any?(request.messages, &(&1[:id] == result_id))
  end

  test "a terminal result containing text blocks is delivered without stopping the manager" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    finish(child, [%{type: :text, text: "block terminal result"}])

    assert_receive {:provider, :root, request, _}, 1_000
    assert %{message: "Wait completed.", timed_out: false} = tool_result(request, "wait_agent")
    assert mailbox_message(request, "block terminal result")
    assert {:ok, _} = MultiAgent.snapshot(runtime)
  end

  test "rebinding the same parent preserves its live mailbox destination" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    root = attach_root(runtime)
    provider = start_root(root)

    assert :ok = MultiAgent.rebind_parent(runtime, root.binding, authority("root"))
    tool(provider, "wait_agent", %{"timeout_ms" => 500})
    wait_registered(runtime)
    tool(child.provider, "send_message", %{"target" => "/root", "message" => "still attached"})

    assert_receive {:provider, :root, request, _}, 1_000
    assert %{message: "Wait completed.", timed_out: false} = tool_result(request, "wait_agent")
    assert mailbox_message(request, "still attached")
  end

  test "an interrupted activation cannot leave steer activity in its replacement" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    pid = :sys.get_state(runtime).agents[child.name].pid
    assert {:ok, _} = Conversation.steer(pid, "old activation steer")
    assert {:ok, _} = call(runtime, "interrupt_agent", %{"target" => child.name})

    assert {:ok, _} =
             call(runtime, "followup_task", %{"target" => child.name, "message" => "fresh"})

    assert_receive {:provider, :child, _, provider}, 1_000
    tool(provider, "wait_agent", %{"timeout_ms" => 10})

    assert_receive {:provider, :child, request, _}, 1_000
    assert %{message: "Wait timed out.", timed_out: true} = tool_result(request, "wait_agent")
    refute Enum.any?(request.messages, &(&1[:content] == "old activation steer"))
  end

  test "terminal result checkpoint refusal leaves parent mail unaccepted and manager responsive" do
    runtime = start_runtime()
    child = spawn_child(runtime)
    gates = :ets.new(:result_delivery_failure, [:set, :public])
    root = attach_root(runtime, store: GateStore, gates: gates)
    _provider = start_root(root)
    :ets.insert(gates, {:fail_next, true})
    finish(child, "refused terminal result")

    assert eventually(fn -> Conversation.status(root.pid).phase == :storage_failed end)

    assert eventually(fn ->
             match?(
               %{status: :failed, error_class: class} when not is_nil(class),
               result_delivery(runtime, child.name)
             )
           end)

    assert %{status: :failed, result_id: result_id} = result_delivery(runtime, child.name)
    assert is_binary(result_id)
    assert Map.get(Conversation.status(root.pid).conversation, :mailbox, []) == []
    refute_receive {:provider, :root, _, _}, 30
  end
end
