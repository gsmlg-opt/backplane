defmodule Backplane.AgentRuntime.ServiceInvocationContextTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Image, Services, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @identity_keys [
    :run_id,
    :incarnation,
    :turn_id,
    :step_id,
    :attempt_id,
    :invocation_id,
    :tool_name,
    :tool_revision,
    :catalog_revision,
    :tool_call_id,
    :enclosing_invocation_id,
    :session_binding_identity
  ]

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

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

  defmodule RecordingStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def load(context, run_id, opts \\ []),
      do: EphemeralStore.load(context.table, run_id, opts)

    def store(context, run, meta) do
      result = EphemeralStore.store(context.table, run, meta)

      case {result, meta.command} do
        {{:ok, _}, {kind, _, %{invocation_id: id}}}
        when kind in [:tool_invoked, :tool_completed] ->
          send(context.test, {:tool_acknowledged, kind, id})

        _ ->
          :ok
      end

      result
    end
  end

  defmodule ImageAdapter do
    def generate(request, opts) do
      send(opts[:test], {:image, request, opts, self()})

      receive do
        :finish -> {:ok, %{artifact: %{id: "fixture-image"}}}
      end
    end
  end

  test "native direct and real Deno image calls retain exact invocation context without replay" do
    assert is_binary(System.find_executable("deno")), "this regression requires real Deno"
    assert CodeMode.lifecycle_capability(%{}) == :verified
    names = ["exec", "image_gen::imagegen"]
    [image] = Services.contracts(%{image_adapter: ImageAdapter})

    authority = %{
      caller: "host",
      run_id: "image-context",
      grants: names,
      tool_revisions: %{"exec" => 1, "image_gen::imagegen" => image.tool_revision}
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 17)

    context = %{
      session_binding: binding,
      image_adapter: ImageAdapter,
      image_options: [test: self(), timeout: 20_000, runtime_context: %{identity: :static}]
    }

    context = Map.put(context, :code_mode_contracts, Services.contracts(context))
    assert {:ok, profile} = Codex.profile(:mixed, context, authority, tools: names)
    assert {:ok, store} = EphemeralStore.new(binding.run_incarnation)

    opts = [
      run_id: authority.run_id,
      incarnation: binding.run_incarnation,
      store: RecordingStore,
      context: %{table: store, test: self()},
      provider: Provider,
      provider_context: %{test: self(), runtime_context: %{identity: :provider}},
      subscriber: self(),
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      catalog_revision: 7,
      session_binding: binding,
      schema_admission: :strict,
      run_timeout: 20_000,
      effect_timeout: 5_000
    ]

    conversation = start_supervised!({Conversation, opts})
    assert {:ok, _} = Conversation.prompt(conversation, "generate images")
    assert_receive {:provider, _, provider}, 3_000

    request = %{
      "prompt" => "raw prompt\r\n你好",
      "transparent_background" => true,
      "referenced_image_paths" => ["one.png"]
    }

    {direct, provider} = image_call(conversation, store, binding, provider, request, :direct)
    {repeated, provider} = image_call(conversation, store, binding, provider, request, :direct)
    assert direct.identity.tool_call_id == repeated.identity.tool_call_id
    assert direct.identity.invocation_id != repeated.identity.invocation_id
    assert direct.identity.step_id != repeated.identity.step_id

    {nested, provider} = image_call(conversation, store, binding, provider, request, :nested)
    assert nested.identity.invocation_id != nested.identity.enclosing_invocation_id
    assert direct.identity.invocation_id == direct.identity.enclosing_invocation_id

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "image-context", %{type: :run_completed}}, 5_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, authority.run_id)
    assert run.state == :completed
    assert run.active_tools == %{}
    assert map_size(run.tool_results) == 4

    images = Enum.filter(run.context.conversation.messages, &(&1[:name] == "image_gen::imagegen"))
    assert length(images) == 2

    assert Enum.map(images, & &1.invocation_id) ==
             [direct.identity.invocation_id, repeated.identity.invocation_id]

    outer = Enum.find(run.context.conversation.messages, &(&1[:name] == "exec"))
    assert outer.result.value == %{"artifact" => %{"id" => "fixture-image"}}

    for runtime <- [direct, repeated, nested] do
      id = runtime.identity.invocation_id
      assert_receive {:tool_acknowledged, :tool_invoked, ^id}
      assert_receive {:tool_acknowledged, :tool_completed, ^id}
      refute_receive {:tool_acknowledged, _, ^id}, 10
      assert run.tool_results[runtime.identity.invocation_id].artifact == %{id: "fixture-image"}

      assert {:error, %Error{class: :resource_conflict}} = runtime.effect_deadline.()
    end

    restored =
      start_supervised!(
        {Conversation, opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, run)},
        id: :restored
      )

    assert Conversation.status(restored).phase == :terminal
    assert Conversation.status(restored).run == run
    refute_receive {:image, _, _, _}, 50
    refute_receive {:provider, _, _}, 50
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  test "standalone adapters retain generate/2 and receive no invented runtime identity" do
    parent = self()

    task =
      Task.async(fn ->
        Image.generate(ImageAdapter, %{"prompt" => "standalone"}, test: parent)
      end)

    assert_receive {:image, %{"prompt" => "standalone"}, opts, adapter}, 1_000
    refute Keyword.has_key?(opts, :runtime_context)
    send(adapter, :finish)
    assert {:ok, %{artifact: %{id: "fixture-image"}}} = Task.await(task)
  end

  test "image timeout is clamped to configuration and propagates live deadline errors" do
    parent = self()
    deadline = fn -> {:ok, %{remaining_ms: 5_000}} end

    task =
      Task.async(fn ->
        Image.generate(ImageAdapter, %{"prompt" => "bounded"},
          test: parent,
          timeout: 500,
          runtime_context: %{effect_deadline: deadline}
        )
      end)

    assert_receive {:image, _, opts, adapter}, 1_000
    assert opts[:timeout] == 500
    send(adapter, :finish)
    assert {:ok, _} = Task.await(task)
    error = Error.new(:resource_conflict, "original effect is no longer live")

    assert {:error, ^error} =
             Image.generate(ImageAdapter, %{"prompt" => "stale"},
               test: self(),
               runtime_context: %{effect_deadline: fn -> {:error, error} end}
             )

    refute_receive {:image, _, _, _}, 20
  end

  defp image_call(conversation, store, binding, provider, request, mode) do
    {name, arguments} =
      if mode == :direct do
        {"image_gen::imagegen", request}
      else
        {"exec", "return await tools.image_gen__imagegen(" <> JSON.encode!(request) <> ");"}
      end

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "reused-call", name: name, arguments: arguments}
         },
         done()
       ]}
    )

    assert_receive {:image, ^request, opts, adapter}, 5_000
    runtime = opts[:runtime_context]
    assert is_map(runtime)

    assert Enum.sort(Map.keys(runtime)) ==
             Enum.sort([
               :identity,
               :resource_owner,
               :resource_owner_pid,
               :effect_owner_pid,
               :effect_deadline
             ])

    assert Enum.sort(Map.keys(runtime.identity)) == Enum.sort(@identity_keys)
    assert {:ok, _} = Evidence.public(runtime.identity)
    state = :sys.get_state(conversation)
    effect = if mode == :direct, do: state.effect, else: state.nested
    assert runtime.effect_owner_pid == effect.task.pid
    assert runtime.effect_owner_pid != adapter
    assert Process.alive?(runtime.effect_owner_pid)
    assert runtime.resource_owner_pid == binding.owner_pid

    assert runtime.resource_owner ==
             Map.put(
               Map.take(binding, [:owner_id, :incarnation, :owner_pid, :resource_registry]),
               :session_binding,
               binding
             )

    assert runtime.identity.session_binding_identity ==
             Map.take(binding, [:run_id, :owner_id, :incarnation, :run_incarnation])

    assert {:ok, budget} = runtime.effect_deadline.()
    assert budget.selected_timeout_ms == 5_000
    assert budget.remaining_ms in 1..5_000
    assert opts[:timeout] in budget.remaining_ms..5_000
    assert opts[:timeout] < 20_000
    assert opts[:test] == self()

    assert {:ok, %{run: active}} = EphemeralStore.load(store, binding.run_id)
    invocation = active.active_tools[runtime.identity.invocation_id]
    assert is_map(invocation)

    assert Map.take(invocation, @identity_keys -- [:session_binding_identity]) ==
             Map.delete(runtime.identity, :session_binding_identity)

    assert invocation.arguments == request
    first_remaining = budget.remaining_ms
    Process.sleep(10)
    assert {:ok, later} = runtime.effect_deadline.()
    assert later.remaining_ms < first_remaining
    send(adapter, :finish)
    assert_receive {:provider, %{messages: messages}, next_provider}, 5_000
    assert List.last(messages).result.is_error == false
    refute_receive {:image, _, _, _}, 10
    {runtime, next_provider}
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
