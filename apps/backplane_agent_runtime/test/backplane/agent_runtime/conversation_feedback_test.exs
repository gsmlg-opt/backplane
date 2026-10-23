defmodule Backplane.AgentRuntime.ConversationFeedbackTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, context, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Hooks do
    def prepare_tool(invocation, context) do
      send(context.test, {:prepare, invocation, context, self()})
      receive do: ({:decision, decision} -> decision)
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:backend, operation, self()})

      receive do
        :finish ->
          {:ok, %{text: "done"}}

        {:nested, name} ->
          operation.backend_context.nested_dispatch.(%{
            tool_name: name,
            arguments: %{"path" => "A"}
          })
      end
    end
  end

  # This adapter is intentionally ephemeral. Gates prove acknowledgement ordering,
  # not durable persistence; the FileStore conformance fixture covers real files.
  defmodule Store do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      {kind, input} =
        case meta.command do
          {kind, _, input} -> {kind, input}
          {kind, _} -> {kind, %{}}
        end

      old = get_in(run, [:context, :conversation]) || %{}
      desired = Map.get(input, :conversation, %{})

      feedback? =
        kind == :conversation_updated and
          Map.get(desired, :host_feedback, []) != Map.get(old, :host_feedback, [])

      resolution? =
        (kind == :conversation_updated and old[:pending_interaction]) &&
          is_nil(desired[:pending_interaction])

      if (context.gate == :feedback and feedback?) or
           (context.gate == :resolution and resolution?) do
        send(context.test, {:held_commit, input, self()})

        receive do
          :commit ->
            EphemeralStore.store(context.table, run, meta)

          :fail ->
            {:error, Error.new(:execution_failure, "injected feedback failure")}

          :lost_ack ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)
            send(context.test, :committed_without_ack)
            receive do: (:never -> :ok)
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "preparation receipt is checkpointed, correlated, JSON safe and explicitly ephemeral" do
    {pid, table} = start()
    {invocation, context, _hook} = begin_tool(pid)
    assert is_function(context.append_feedback, 1)
    assert {:ok, receipt} = context.append_feedback.(payload())
    assert receipt.id == "feedback-1"
    assert receipt.store_mode == :ephemeral
    assert receipt.revision > 0

    for key <- [
          :run_id,
          :incarnation,
          :turn_id,
          :step_id,
          :attempt_id,
          :invocation_id,
          :tool_call_id,
          :tool_name,
          :tool_revision,
          :catalog_revision
        ] do
      assert receipt.correlation[key] == invocation[key]
    end

    assert {:ok, stored} = EphemeralStore.load(table, "feedback")
    assert [record] = stored.run.context.conversation.host_feedback
    assert record["id"] == "feedback-1"
    assert record["text"] == "host context"
    assert record["revision"] == receipt.revision
    assert record["store_mode"] == "ephemeral"
    assert record["projected"] == false
    assert JSON.decode!(JSON.encode!(record)) == record
    refute_receive {:backend, _, _}, 20
  end

  test "payload validation rejects missing, empty, oversized, ambiguous and private fields" do
    {pid, _} = start()
    {_, context, _} = begin_tool(pid)

    for invalid <- [
          %{},
          Map.delete(payload(), :stage),
          %{payload() | id: ""},
          %{payload() | text: <<255>>},
          %{payload() | text: :not_a_string},
          %{payload() | id: String.duplicate("x", 257)},
          %{payload() | source: String.duplicate("x", 257)},
          %{payload() | stage: String.duplicate("x", 257)},
          %{payload() | text: String.duplicate("x", 65_537)},
          Map.put(payload(), "id", "feedback-1"),
          Map.put(payload(), :run_id, "forged"),
          Map.put(payload(), :authority, %{}),
          Map.put(payload(), :unknown, "extra"),
          []
        ] do
      assert {:error, %Error{class: :validation}} = context.append_feedback.(invalid)
    end

    assert Conversation.status(pid).conversation.host_feedback == []

    assert {:ok, _} =
             context.append_feedback.(%{
               "id" => "unicode",
               "text" => "上下文",
               "source" => "hooks",
               "stage" => "PreToolUse"
             })
  end

  test "deduplication returns original receipt only for identical live invocation" do
    {pid, _} = start()
    {_, context, _} = begin_tool(pid)
    assert {:ok, first} = context.append_feedback.(payload())
    assert {:ok, ^first} = context.append_feedback.(payload())

    for changed <- [
          %{payload() | text: "different"},
          %{payload() | source: "other"},
          %{payload() | stage: "PostToolUse"}
        ] do
      assert {:error, %Error{class: :resource_conflict}} = context.append_feedback.(changed)
    end

    assert {:ok, _} = context.append_feedback.(%{payload() | id: "feedback-2"})

    assert Enum.map(Conversation.status(pid).conversation.host_feedback, & &1["id"]) == [
             "feedback-1",
             "feedback-2"
           ]
  end

  test "held commit never acknowledges feedback or dispatches preparation early" do
    {pid, _} = start(gate: :feedback)
    {_, context, hook} = begin_tool(pid)
    task = Task.async(fn -> context.append_feedback.(payload()) end)
    assert_receive {:held_commit, _, store}, 1_000
    assert Task.yield(task, 10) == nil
    refute_receive {:backend, _, _}, 20
    send(store, :commit)
    assert {:ok, _} = Task.await(task)
    send(hook, {:decision, :allow})
    assert_receive {:backend, _, _}, 1_000
    assert length(Conversation.status(pid).conversation.host_feedback) == 1
  end

  test "cancellation during blocked commit rejects caller and fences late acknowledgement" do
    {pid, table} = start(gate: :feedback)
    {_, context, _} = begin_tool(pid)
    task = Task.async(fn -> context.append_feedback.(payload()) end)
    assert_receive {:held_commit, _, store}, 1_000
    assert :ok = Conversation.cancel(pid)
    assert {:error, %Error{class: :cancelled}} = Task.await(task)
    send(store, :commit)
    assert_receive {:agent_runtime, "feedback", %{type: :run_cancelled}}, 1_000
    refute_receive {:backend, _, _}, 20
    assert {:error, %Error{}} = context.append_feedback.(payload())
    assert {:ok, snapshot} = EphemeralStore.load(table, "feedback")
    assert [%{"id" => "feedback-1"}] = snapshot.run.context.conversation.host_feedback
  end

  for outcome <- [:fail, :lost_ack] do
    test "#{outcome} cannot produce a successful feedback receipt" do
      {pid, _} = start(gate: :feedback, commit_timeout: 200)
      {_, context, _} = begin_tool(pid)
      task = Task.async(fn -> context.append_feedback.(payload()) end)
      assert_receive {:held_commit, _, store}, 1_000
      send(store, unquote(outcome))
      assert {:error, %Error{}} = Task.await(task)
      assert Conversation.status(pid).phase == :storage_failed
      refute_receive {:backend, _, _}, 20
    end
  end

  test "completed and cancelled producers fail before exact-ID deduplication" do
    {pid, _} = start()
    {_, context, hook} = begin_tool(pid)
    assert {:ok, _} = context.append_feedback.(payload())
    send(hook, {:decision, :allow})
    assert_receive {:backend, operation, _}, 1_000
    assert {:error, %Error{class: :resource_conflict}} = context.append_feedback.(payload())

    assert {:error, %Error{class: :resource_conflict}} =
             GenServer.call(pid, {:append_feedback, make_ref(), payload()})

    assert :ok = Conversation.cancel(pid)
    assert {:error, %Error{}} = operation.backend_context.append_feedback.(payload())
  end

  for decision <- [{:deny, "policy"}, {:allow, %{"path" => 42}}] do
    test "acknowledged feedback survives preparation #{inspect(decision)} without dispatch" do
      {pid, _} = start()
      {_, context, hook} = begin_tool(pid)
      assert {:ok, _} = context.append_feedback.(payload())
      send(hook, {:decision, unquote(Macro.escape(decision))})
      assert_receive {:provider, request, _, _}, 1_000
      assert Enum.any?(request.messages, &Map.has_key?(&1, :host_feedback))

      assert [%{"id" => "feedback-1", "projected" => true}] =
               Conversation.status(pid).conversation.host_feedback

      refute_receive {:backend, _, _}, 20
    end
  end

  test "approval rewrite and refusal preserve invocation feedback" do
    {pid, _} = start(approval: true)
    {invocation, context, hook} = begin_tool(pid)
    assert {:ok, receipt} = context.append_feedback.(payload())
    send(hook, {:decision, {:allow, %{"path" => "B"}}})

    assert_receive {:agent_runtime, "feedback",
                    %{type: :interaction_requested, interaction_id: first}},
                   1_000

    assert :ok = Conversation.resolve(pid, first, {:update_input, %{"path" => "C"}})

    assert_receive {:agent_runtime, "feedback",
                    %{
                      type: :interaction_requested,
                      interaction_id: second,
                      request: %{operation: operation}
                    }},
                   1_000

    assert operation.arguments == %{"path" => "C"}
    assert operation.invocation_id == receipt.correlation.invocation_id
    assert invocation.invocation_id == operation.invocation_id
    assert :ok = Conversation.resolve(pid, second, :denied)
    assert_receive {:provider, _, _, _}, 1_000
    assert length(Conversation.status(pid).conversation.host_feedback) == 1
    refute_receive {:backend, _, _}, 20
  end

  test "custom preparation and direct backend feedback project after the complete tool batch once" do
    {pid, _} = start(custom: true)

    {_, context, hook} =
      begin_tool(pid, [call("one", "read", "raw"), call("two", "read", "second")])

    assert {:ok, _} = context.append_feedback.(payload())
    send(hook, {:decision, {:allow, "rewritten"}})
    assert_receive {:backend, %{arguments: "rewritten"} = operation, backend}, 1_000
    assert {:ok, _} = operation.backend_context.append_feedback.(%{payload() | id: "backend"})
    send(backend, :finish)
    assert_receive {:prepare, _, _, second_hook}, 1_000
    send(second_hook, {:decision, :allow})
    assert_receive {:backend, _, second_backend}, 1_000
    refute_receive {:provider, _, _, _}, 20
    send(second_backend, :finish)
    assert_receive {:provider, request, provider_context, provider}, 1_000
    refute Map.has_key?(provider_context, :append_feedback)

    assert Enum.map(request.messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :tool,
             :user,
             :user
           ]

    feedback = Enum.filter(request.messages, &Map.has_key?(&1, :host_feedback))
    assert length(feedback) == 2
    assert Enum.all?(feedback, &String.contains?(String.downcase(&1.content), "host feedback"))
    assert Enum.map(feedback, & &1.host_feedback["id"]) == ["feedback-1", "backend"]

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert_receive {:agent_runtime, "feedback", %{type: :run_completed}}, 1_000
    refute_receive {:provider, _, _, _}, 20
    assert Enum.count(Conversation.status(pid).messages, &Map.has_key?(&1, :host_feedback)) == 2
  end

  test "nested preparation and backend stamp their enclosing invocation" do
    {pid, _} = start()
    {outer_invocation, _, hook} = begin_tool(pid, [call("outer", "outer", %{"path" => "A"})])
    send(hook, {:decision, :allow})
    assert_receive {:backend, _, outer}, 1_000
    send(outer, {:nested, "read"})
    assert_receive {:prepare, nested_invocation, context, nested_hook}, 1_000
    assert {:ok, receipt} = context.append_feedback.(payload())
    assert receipt.correlation.invocation_id == nested_invocation.invocation_id
    assert receipt.correlation.enclosing_invocation_id == outer_invocation.invocation_id
    send(nested_hook, {:decision, :allow})
    assert_receive {:backend, nested_operation, nested}, 1_000

    assert {:ok, backend_receipt} =
             nested_operation.backend_context.append_feedback.(%{
               payload()
               | id: "nested-backend"
             })

    assert backend_receipt.correlation.enclosing_invocation_id == outer_invocation.invocation_id
    send(nested, :finish)
    assert_receive {:provider, request, _, _}, 1_000
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 2
    assert {:error, %Error{class: :resource_conflict}} = context.append_feedback.(payload())
  end

  test "history seed preserves original identity, projected messages and dedup across replacement" do
    {pid, _} = start()
    {_, context, hook} = begin_tool(pid)
    assert {:ok, receipt} = context.append_feedback.(payload())
    send(hook, {:decision, {:deny, "policy"}})
    assert_receive {:provider, request, _, _}, 1_000
    seed = Conversation.status(pid).conversation.host_feedback

    {replacement, _} =
      start(run_id: "replacement", messages: request.messages, host_feedback: seed)

    {_, replacement_context, _} =
      begin_tool(replacement, [call("new", "read", %{"path" => "A"})], false)

    assert {:error, %Error{class: :resource_conflict}} =
             replacement_context.append_feedback.(payload())

    assert [record] = Conversation.status(replacement).conversation.host_feedback
    assert record["correlation"]["run_id"] == receipt.correlation.run_id

    assert Enum.count(
             Conversation.status(replacement).messages,
             &Map.has_key?(&1, :host_feedback)
           ) == 1
  end

  test "context reset retains the ID ledger and unprojected feedback" do
    {pid, _} = start()
    {_, _, hook} = begin_tool(pid)
    send(hook, {:decision, :allow})
    assert_receive {:backend, operation, backend}, 1_000
    assert {:ok, _} = operation.backend_context.append_feedback.(payload())
    assert :ok = operation.backend_context.request_new_context.()
    send(backend, :finish)
    assert_receive {:provider, request, _, provider}, 1_000
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 1
    send(provider, {:events, tool_events([call("next", "read", %{"path" => "B"})])})
    assert_receive {:prepare, _, context, _}, 1_000
    assert {:error, %Error{class: :resource_conflict}} = context.append_feedback.(payload())
  end

  test "queued steering and tool completion preserve committed feedback and projection state" do
    {pid, _} = start(gate: :feedback)
    {_, context, hook} = begin_tool(pid)
    feedback = Task.async(fn -> context.append_feedback.(payload()) end)
    assert_receive {:held_commit, _, first_store}, 1_000
    steering = Task.async(fn -> Conversation.steer(pid, "queued guidance") end)
    send(first_store, :commit)
    assert {:ok, _} = Task.await(feedback)
    assert {:ok, _} = Task.await(steering)
    send(hook, {:decision, :allow})
    assert_receive {:backend, _, backend}, 1_000
    send(backend, :finish)
    assert_receive {:held_commit, _, projection_store}, 1_000
    refute_receive {:provider, _, _, _}, 20
    send(projection_store, :commit)
    assert_receive {:provider, request, _, _}, 1_000
    assert Enum.any?(request.messages, &(&1[:content] == "queued guidance"))
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 1

    assert [%{"id" => "feedback-1", "projected" => true}] =
             Conversation.status(pid).conversation.host_feedback
  end

  test "nested feedback capability is fenced when its enclosing backend completes" do
    {pid, _} = start()
    {_, _, hook} = begin_tool(pid, [call("outer", "outer", %{"path" => "A"})])
    send(hook, {:decision, :allow})
    assert_receive {:backend, operation, outer}, 1_000

    nested =
      Task.async(fn ->
        operation.backend_context.nested_dispatch.(%{
          tool_name: "read",
          arguments: %{"path" => "A"}
        })
      end)

    assert_receive {:prepare, _, context, _}, 1_000
    send(outer, :finish)
    assert {:error, %Error{}} = Task.await(nested)
    assert {:error, %Error{class: :resource_conflict}} = context.append_feedback.(payload())
    refute_receive {:backend, %{tool_name: "read"}, _}, 20
  end

  test "nested completion queued behind outer feedback checkpoint retains its ledger" do
    {pid, _} = start(gate: :feedback)
    {_, _, hook} = begin_tool(pid, [call("outer", "outer", %{"path" => "A"})])
    send(hook, {:decision, :allow})
    assert_receive {:backend, outer_operation, outer}, 1_000
    send(outer, {:nested, "read"})
    assert_receive {:prepare, _, _, nested_hook}, 1_000
    send(nested_hook, {:decision, :allow})
    assert_receive {:backend, _, nested}, 1_000
    feedback = Task.async(fn -> outer_operation.backend_context.append_feedback.(payload()) end)
    assert_receive {:held_commit, _, store}, 1_000
    send(nested, :finish)
    # Same sender barrier after observing nested completion ensures the queued
    # completion captured the conversation before the feedback Store ACK.
    await_queued_commit(pid)
    send(store, :commit)
    assert {:ok, _} = Task.await(feedback)
    assert_receive {:held_commit, _, projection}, 1_000
    send(projection, :commit)
    assert_receive {:provider, request, _, _}, 1_000
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 1

    assert [%{"id" => "feedback-1", "projected" => true}] =
             Conversation.status(pid).conversation.host_feedback
  end

  test "canonical messages alone rebuild projected ledger with original foreign-run identity" do
    {pid, _} = start()
    {_, context, hook} = begin_tool(pid)
    assert {:ok, receipt} = context.append_feedback.(payload())
    send(hook, {:decision, {:deny, "policy"}})
    assert_receive {:provider, request, _, _}, 1_000
    {replacement, _} = start(run_id: "messages-only", messages: request.messages)

    {_, replacement_context, _} =
      begin_tool(replacement, [call("next", "read", %{"path" => "A"})], false)

    assert {:error, %Error{class: :resource_conflict}} =
             replacement_context.append_feedback.(payload())

    assert [record] = Conversation.status(replacement).conversation.host_feedback
    assert record["correlation"]["run_id"] == receipt.correlation.run_id
    assert record["projected"]

    assert Enum.count(
             Conversation.status(replacement).messages,
             &Map.has_key?(&1, :host_feedback)
           ) == 1
  end

  test "invalid history metadata is rejected before starting a Conversation" do
    for metadata <- [%{"source" => %{}}, %{"id" => "duplicate", id: "duplicate"}, %{id: self()}] do
      message = %{role: :user, content: "[Host feedback] malformed", host_feedback: metadata}

      assert {:error, %Error{class: :validation}} =
               Conversation.start_link(run_id: "invalid", messages: [message])
    end

    assert {:error, %Error{class: :validation}} =
             Conversation.start_link(run_id: "invalid", host_feedback: [%{"id" => "partial"}])
  end

  test "a later natural turn includes existing feedback once and rejects reusing its ID" do
    {pid, _} = start()
    {_, context, hook} = begin_tool(pid)
    assert {:ok, _} = context.append_feedback.(payload())
    send(hook, {:decision, {:deny, "policy"}})
    assert_receive {:provider, _, _, provider}, 1_000
    assert {:ok, _} = Conversation.follow_up(pid, "next turn")

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert_receive {:provider, request, _, next}, 1_000
    assert Enum.count(request.messages, &Map.has_key?(&1, :host_feedback)) == 1
    send(next, {:events, tool_events([call("next", "read", %{"path" => "A"})])})
    assert_receive {:prepare, _, later_context, _}, 1_000
    assert {:error, %Error{class: :resource_conflict}} = later_context.append_feedback.(payload())
  end

  test "interaction public normalization rejects private and ambiguous values before admission" do
    assert {:ok, %{"kind" => "permission", "nested" => [%{"allowed" => true}]}} =
             Conversation.public_interaction(%{kind: :permission, nested: [%{allowed: true}]})

    deep = Enum.reduce(1..34, "leaf", fn _, acc -> [acc] end)
    assert {:error, %Error{class: :validation}} = Conversation.public_interaction(deep)

    assert {:error, %Error{class: :validation}} =
             Conversation.public_interaction(String.duplicate("x", 262_145))

    {pid, _} = start()
    {_, context, _} = begin_tool(pid)

    for value <- [
          self(),
          make_ref(),
          fn -> :ok end,
          {:tuple, 1},
          <<255>>,
          %{"kind" => "two", kind: :one}
        ] do
      assert {:error, %Error{class: :validation}} = context.interact.(%{value: value})
    end

    assert Conversation.status(pid).conversation.pending_interaction == nil
  end

  test "interaction atom keys stringify while boolean and nil values retain JSON types" do
    assert {:ok, %{"true" => false, "false" => nil, "nil" => true}} =
             Conversation.public_interaction(%{true => false, false => nil, nil => true})

    for key <- [true, false, nil] do
      assert {:error, %Error{class: :validation}} =
               Conversation.public_interaction(%{key => 1, Atom.to_string(key) => 2})
    end

    {pid, _} = start()
    {_, context, _} = begin_tool(pid)
    requester = Task.async(fn -> context.interact.(%{true => false, nil => nil}) end)

    assert_receive {:agent_runtime, "feedback",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    assert {:ok, %{"true" => false, "nil" => nil}} =
             Conversation.public_interaction(
               Conversation.status(pid).conversation.pending_interaction.request
             )

    assert :ok = Conversation.resolve(pid, id, "accepted")
    assert {:ok, "accepted"} = Task.await(requester)
  end

  test "held resolution cannot release worker after cancellation" do
    {pid, _} = start(gate: :resolution)
    {_, context, _} = begin_tool(pid)
    waiter = Task.async(fn -> context.interact.(%{kind: :permission}) end)

    assert_receive {:agent_runtime, "feedback",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    resolver = Task.async(fn -> Conversation.resolve(pid, id, :approved) end)
    assert_receive {:held_commit, _, store}, 1_000
    assert :ok = Conversation.cancel(pid)
    assert {:error, %Error{class: :cancelled}} = Task.await(waiter)
    assert {:error, %Error{class: :cancelled}} = Task.await(resolver)
    send(store, :commit)
    assert_receive {:agent_runtime, "feedback", %{type: :run_cancelled}}, 1_000
    refute_receive {:agent_runtime, "feedback", %{type: :interaction_resolved}}, 20
    assert {:error, %Error{}} = Conversation.resolve(pid, id, :approved)
  end

  test "resolution storage failure clears actionable interaction and wakes waiters" do
    {pid, _} = start(gate: :resolution)
    {_, context, _} = begin_tool(pid)
    waiter = Task.async(fn -> context.interact.(%{kind: :permission}) end)

    assert_receive {:agent_runtime, "feedback",
                    %{type: :interaction_requested, interaction_id: id}},
                   1_000

    resolver = Task.async(fn -> Conversation.resolve(pid, id, :approved) end)
    assert_receive {:held_commit, _, store}, 1_000
    send(store, :fail)
    assert {:error, %Error{}} = Task.await(waiter)
    assert {:error, %Error{}} = Task.await(resolver)
    assert Conversation.status(pid).phase == :storage_failed
    assert Conversation.status(pid).conversation.pending_interaction == nil
    assert {:error, %Error{class: :resource_conflict}} = Conversation.resolve(pid, id, :approved)
  end

  defp await_queued_commit(pid, attempts \\ 100)
  defp await_queued_commit(_pid, 0), do: flunk("nested completion did not enter the commit queue")

  defp await_queued_commit(pid, attempts) do
    if :queue.is_empty(:sys.get_state(pid).commit_queue) do
      Process.sleep(5)
      await_queued_commit(pid, attempts - 1)
    else
      :ok
    end
  end

  defp payload,
    do: %{id: "feedback-1", text: "host context", source: "sigma-hooks", stage: "PreToolUse"}

  defp call(id, name, arguments), do: %{id: id, name: name, arguments: arguments}

  defp tool_events(calls) do
    Enum.map(calls, &%{type: :tool_call_completed, tool_call: &1}) ++
      [%{type: :response_completed, message: %{role: :assistant, content: "tools"}}]
  end

  defp begin_tool(pid, calls \\ [call("call", "read", %{"path" => "A"})], first? \\ true) do
    assert {:ok, _} = Conversation.prompt(pid, "go")
    assert_receive {:provider, request, _, provider}, 1_000
    if first?, do: assert(match?([%{role: :user, content: "go"}], request.messages))
    send(provider, {:events, tool_events(calls)})
    assert_receive {:prepare, invocation, context, hook}, 1_000
    {invocation, context, hook}
  end

  defp start(opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)
    run_id = Keyword.get(opts, :run_id, "feedback")

    registry =
      Enum.reduce(["read", "outer"], %ToolRegistry{}, fn name, registry ->
        {:ok, registry} =
          ToolRegistry.register(registry, %{
            tool_name: name,
            tool_revision: 1,
            codex_input_kind: if(opts[:custom], do: :custom, else: :function),
            schema: %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"]
            },
            safety: %{
              read_only: true,
              retry_safe: true,
              parallel_safe: false,
              requires_approval: opts[:approval] && name == "read"
            },
            backend: Backend,
            backend_context: %{test: self()}
          })

        registry
      end)

    options =
      Keyword.merge(
        [
          run_id: run_id,
          store: Store,
          context: %{table: table, test: self(), gate: opts[:gate]},
          provider: Provider,
          provider_context: %{test: self()},
          hooks: Hooks,
          registry: registry,
          subscriber: self(),
          authority: %{
            caller: "host",
            run_id: run_id,
            grants: ["read", "outer"],
            tool_revision: 1
          },
          work: 40,
          run_timeout: 10_000
        ],
        Keyword.take(opts, [:run_id, :messages, :host_feedback, :commit_timeout])
      )

    {start_supervised!({Conversation, options}, id: make_ref()), table}
  end
end
