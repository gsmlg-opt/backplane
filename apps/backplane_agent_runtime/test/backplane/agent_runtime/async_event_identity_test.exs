defmodule Backplane.AgentRuntime.AsyncEventIdentityTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Contract, Control, ResourceRegistry}

  @async_tools ~w(request_user_input_async send_message_to_user_async)

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

  defmodule Store do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      result = EphemeralStore.store(context.table, run, meta)

      if match?({:ok, _}, result) do
        case meta.command do
          {:tool_invoked, _, invocation} -> send(context.test, {:checkpoint, invocation})
          _ -> :ok
        end
      end

      result
    end
  end

  defmodule Probe do
    def execute(operation) do
      send(operation.backend_context.test, {:probe, operation, self()})
      receive do: (:finish -> {:ok, %{accepted: true}})
    end
  end

  defmodule Hooks do
    def prepare_tool(invocation, context) do
      send(context.test, {:preparing, invocation, context, self()})
      receive do: (:allow -> :allow)
    end
  end

  test "identical direct async calls expose distinct checkpointed identities" do
    run_id = "async-direct-identity"
    {conversation, table} = start(run_id, control_profile(run_id))
    assert {:ok, _} = Conversation.prompt(conversation, "ask twice and notify")
    assert_receive {:provider, _, _, provider}

    events(provider, [
      {"question-one", "request_user_input_async", %{"questions" => [%{"title" => "Continue?"}]}},
      {"question-two", "request_user_input_async", %{"questions" => [%{"title" => "Continue?"}]}},
      {"notice-one", "send_message_to_user_async", %{"message" => "Working"}}
    ])

    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_input_requested} = first}
    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_input_requested} = second}
    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_message} = notice}
    assert first.questions == second.questions
    assert is_binary(first.invocation_id)
    assert first.invocation_id != second.invocation_id
    assert first.tool_call_id == "question-one"
    assert second.tool_call_id == "question-two"
    assert notice.tool_call_id == "notice-one"

    metadata = [:run_id, :incarnation, :step_id, :attempt_id, :turn_id]
    assert Map.take(first, metadata) == Map.take(second, metadata)

    for event <- [first, second, notice] do
      assert_checkpoint(event)
      assert {:ok, public} = Conversation.public_interaction(event)
      assert public["invocation_id"] == event.invocation_id
      assert public["tool_call_id"] == event.tool_call_id
      assert JSON.decode!(JSON.encode!(public)) == public
    end

    assert_receive {:provider, %{messages: messages}, _, final_provider}
    results = Enum.filter(messages, &(&1.role == :tool))
    assert length(results) == 3
    assert Enum.all?(results, &(&1.result.accepted == true))
    finish(run_id, final_provider)

    assert {:ok, stored} = EphemeralStore.load(table, run_id)

    for event <- [first, second, notice] do
      assert Map.has_key?(stored.run.tool_results, event.invocation_id)

      assert Enum.any?(stored.run.context.conversation.messages, fn message ->
               message[:role] == :tool and message[:tool_call_id] == event.tool_call_id
             end)
    end
  end

  test "real Code Mode async events use each nested call rather than the outer call" do
    run_id = "async-nested-identity"
    registry = start_supervised!(ResourceRegistry)
    authority = authority(run_id, ["exec", "wait" | @async_tools])

    assert {:ok, profile} =
             Codex.profile(
               :code_mode_only,
               %{
                 resource_registry: registry,
                 code_mode_contracts:
                   Enum.filter(Control.contracts(%{root?: true}), &(&1.name in @async_tools))
               },
               authority
             )

    {conversation, table} = start(run_id, profile)
    assert {:ok, _} = Conversation.prompt(conversation, "ask inside code")
    assert_receive {:provider, _, _, provider}

    source = """
    await codex.tool('request_user_input_async', {questions:[{title:'Continue?'}]});
    await codex.tool('request_user_input_async', {questions:[{title:'Continue?'}]});
    return await codex.tool('send_message_to_user_async', {message:'Working'});
    """

    events(provider, [{"outer-code-call", "exec", source}])

    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_input_requested} = first}, 5_000
    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_input_requested} = second}, 5_000
    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_message} = notice}, 5_000

    assert length(Enum.uniq(Enum.map([first, second, notice], & &1.invocation_id))) == 3
    assert length(Enum.uniq(Enum.map([first, second, notice], & &1.tool_call_id))) == 3

    for event <- [first, second, notice] do
      assert event.tool_call_id != "outer-code-call"
      assert String.starts_with?(event.invocation_id, "nested_invocation_")
      assert String.starts_with?(event.tool_call_id, "nested_call_")
      assert_checkpoint(event)
    end

    assert_receive {:provider, _, _, final_provider}, 5_000
    finish(run_id, final_provider)
    assert {:ok, stored} = EphemeralStore.load(table, run_id)

    assert Enum.all?(
             [first, second, notice],
             &Map.has_key?(stored.run.tool_results, &1.invocation_id)
           )
  end

  test "trusted live tool identity overwrites spoofed payload IDs and expires after completion" do
    run_id = "async-spoofed-identity"
    {conversation, _} = start(run_id, probe_profile(run_id))
    assert {:ok, _} = Conversation.prompt(conversation, "probe")
    assert_receive {:provider, _, _, provider}
    events(provider, [{"probe-call", "probe", %{}}])
    assert_receive {:probe, operation, worker}
    emit = operation.backend_context.emit

    assert :ok =
             emit.(%{
               "invocation_id" => "forged-string-invocation",
               "tool_call_id" => "forged-string-call",
               type: :async_user_message,
               message: "Working",
               invocation_id: "forged-invocation",
               tool_call_id: "forged-call",
               run_id: "forged-run"
             })

    assert_receive {:agent_runtime, ^run_id, %{type: :async_user_message} = event}
    assert event.invocation_id == operation.invocation_id
    assert event.tool_call_id == operation.tool_call_id
    assert {:ok, public} = Conversation.public_interaction(event)
    assert public["invocation_id"] == operation.invocation_id
    assert public["tool_call_id"] == operation.tool_call_id
    assert_checkpoint(event)
    assert :ok = emit.(%{metadata: "generic event"})
    assert_receive {:agent_runtime, ^run_id, %{metadata: "generic event"}}

    send(worker, :finish)
    assert_receive {:provider, _, _, final_provider}

    assert {:error, %Error{class: :resource_conflict}} =
             emit.(%{type: :async_user_message, message: "too late"})

    finish(run_id, final_provider)
  end

  test "provider and preparation callbacks cannot manufacture native async call events" do
    run_id = "async-non-tool-identity"
    {conversation, _} = start(run_id, probe_profile(run_id), hooks: Hooks)
    assert {:ok, _} = Conversation.prompt(conversation, "probe")
    assert_receive {:provider, _, provider_context, provider}
    event = %{type: :async_user_message, message: "manufactured"}
    assert {:error, %Error{class: :resource_conflict}} = provider_context.emit.(event)
    events(provider, [{"probe-call", "probe", %{}}])
    assert_receive {:preparing, _, preparation_context, hook}
    refute Map.has_key?(preparation_context, :emit)
    assert {:error, %Error{class: :resource_conflict}} = provider_context.emit.(event)
    send(hook, :allow)
    assert_receive {:probe, _, worker}
    send(worker, :finish)
    assert_receive {:provider, _, _, final_provider}
    finish(run_id, final_provider)
  end

  test "cancellation fences a captured async emission callback" do
    run_id = "async-cancelled-identity"
    {conversation, _} = start(run_id, probe_profile(run_id))
    assert {:ok, _} = Conversation.prompt(conversation, "probe")
    assert_receive {:provider, _, _, provider}
    events(provider, [{"probe-call", "probe", %{}}])
    assert_receive {:probe, operation, _}
    assert :ok = Conversation.cancel(conversation)

    assert {:error, %Error{class: :resource_conflict}} =
             operation.backend_context.emit.(%{type: :async_user_message, message: "cancelled"})

    refute_receive {:agent_runtime, ^run_id, %{type: :async_user_message}}
  end

  test "native async tools continue with accepted results without any subscriber" do
    run_id = "async-no-subscriber-identity"
    {conversation, _} = start(run_id, control_profile(run_id), subscriber: nil)
    assert {:ok, _} = Conversation.prompt(conversation, "notify")
    assert_receive {:provider, _, _, provider}

    events(provider, [
      {"question-one", "request_user_input_async", %{"questions" => [%{"title" => "Continue?"}]}},
      {"notice-one", "send_message_to_user_async", %{"message" => "Working"}}
    ])

    assert_receive {:provider, %{messages: messages}, _, final_provider}
    results = Enum.filter(messages, &(&1.role == :tool))
    assert length(results) == 2
    assert Enum.all?(results, &(&1.result.accepted == true))
    events(final_provider, [])
    refute_receive {:agent_runtime, ^run_id, _}
  end

  defp control_profile(run_id) do
    {:ok, profile} =
      Codex.profile(:interactive, %{root?: true}, authority(run_id, @async_tools),
        tools: @async_tools
      )

    profile
  end

  defp probe_profile(run_id) do
    {:ok, contract} =
      Contract.new(%{
        name: "probe",
        description: "Emit from a live test backend",
        schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        backend: Probe,
        backend_context: %{test: self()},
        safety: %{read_only: true, retry_safe: true, parallel_safe: false}
      })

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, Contract.descriptor(contract))

    %{
      registry: registry,
      tools: [Contract.provider_definition(contract)],
      authority: authority(run_id, ["probe"])
    }
  end

  defp authority(run_id, names) do
    %{caller: "host", run_id: run_id, grants: names, tool_revisions: Map.new(names, &{&1, 1})}
  end

  defp start(run_id, profile, opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         Keyword.merge(
           [
             run_id: run_id,
             store: Store,
             context: %{table: table, test: self()},
             provider: Provider,
             provider_context: %{test: self()},
             subscriber: self(),
             registry: profile.registry,
             tools: profile.tools,
             authority: profile.authority,
             schema_admission: :strict,
             run_timeout: 15_000,
             effect_timeout: 5_000,
             cleanup_timeout: 3_000,
             work: 20
           ],
           opts
         )}
      )

    {conversation, table}
  end

  defp events(provider, calls) do
    send(provider, {
      :events,
      Enum.map(calls, fn {id, name, arguments} ->
        %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}
      end) ++ [%{type: :response_completed, message: %{role: :assistant, content: "issued"}}]
    })
  end

  defp finish(run_id, provider) do
    events(provider, [])
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
  end

  defp assert_checkpoint(event) do
    invocation_id = event.invocation_id
    tool_call_id = event.tool_call_id
    assert_receive {:checkpoint, %{invocation_id: ^invocation_id, tool_call_id: ^tool_call_id}}
  end
end
