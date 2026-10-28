defmodule Backplane.AgentRuntime.ConversationCodeModeContextTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Session}

  @moduletag :tmp_dir
  @runtime_keys [
    :append_feedback,
    :catalog_snapshot,
    :cancellation_coordinator,
    :effect_deadline,
    :emit,
    :interact,
    :nested_dispatch,
    :register_cancellation,
    :register_code_mode,
    :request_new_context,
    :resource_owner_pid,
    :stage_catalog
  ]

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, context.catalog_snapshot, self()})

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

  defmodule FileReader do
    def execute(operation) do
      context = operation.backend_context
      content = File.read!(Path.join(context.workspace, operation.arguments["path"]))
      send(context.test, {:file_read, operation})
      {:ok, %{text: content}}
    end
  end

  test "ordinary host reads preserve direct context through real Deno and continue", ctx do
    assert is_binary(System.find_executable("deno")), "this regression requires real Deno"
    assert CodeMode.lifecycle_capability(%{}) == :verified
    File.write!(Path.join(ctx.tmp_dir, "catalog.txt"), "pinned file\n")
    File.write!(Path.join(ctx.tmp_dir, "following.txt"), "following operation\n")

    names = ["exec", "fixture::read_file", "wait"]
    authority = %{caller: "host", run_id: "code-mode-context", grants: names, tool_revision: 1}
    previous = start_supervised!({Session, owner_pid: self()}, id: :previous_session)
    previous_incarnation = Session.status(previous).incarnation
    assert {:ok, %{status: :confirmed}} = Session.close(previous)
    assert :ok = stop_supervised(:previous_session)

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 17)
    assert binding.incarnation > previous_incarnation
    assert binding.run_incarnation == 17

    domain = %{
      test: self(),
      workspace: ctx.tmp_dir,
      credential: "descriptor credential",
      provider_marker: :descriptor_marker,
      provider_emit: :descriptor_emit,
      producer_invocation: :descriptor_producer,
      publication_boundary: :descriptor_boundary
    }

    descriptor = %{
      name: "read_file",
      namespace: "fixture",
      description: "Read one finite host fixture file",
      revision: 1,
      backend: FileReader,
      backend_context: domain,
      schema: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"],
        "additionalProperties" => false
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

    assert {:ok, profile} =
             Codex.profile(
               :mixed,
               %{session_binding: binding, code_mode_contracts: [descriptor]},
               authority,
               tools: names
             )

    assert {:ok, store} = EphemeralStore.new(binding.run_incarnation)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: authority.run_id,
         incarnation: binding.run_incarnation,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{
           test: self(),
           workspace: "provider workspace",
           credential: "provider credential",
           provider_marker: :provider_marker,
           provider_only: :private_configuration,
           producer_invocation: :provider_producer,
           publication_boundary: :provider_boundary,
           catalog_snapshot: :spoofed
         },
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         catalog_revision: 7,
         session_binding: binding,
         schema_admission: :strict,
         run_timeout: 15_000,
         effect_timeout: 5_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "read directly and through exec")
    assert_receive {:provider, %{catalog_revision: 7}, catalog, provider}, 3_000
    assert catalog.registry == profile.registry
    assert catalog.authority == profile.authority
    assert catalog.tools == profile.tools

    call(provider, "direct-read", "fixture::read_file", %{"path" => "catalog.txt"})
    assert_receive {:file_read, direct}, 3_000
    assert_context(direct, conversation, domain, binding, catalog)
    assert direct.tool_call_id == "direct-read"
    assert direct.enclosing_invocation_id == direct.invocation_id

    assert_receive {:provider, %{messages: messages}, ^catalog, provider}, 3_000
    assert %{text: "pinned file\n", is_error: false} = List.last(messages).result

    code = """
    const read = await tools.fixture__read_file({path: 'catalog.txt'});
    const next = await tools.fixture__read_file({path: 'following.txt'});
    return {read: read.text, next: next.text};
    """

    call(provider, "nested-reads", "exec", code)
    assert_receive {:file_read, nested}, 3_000
    assert_receive {:file_read, following}, 3_000
    assert_receive {:provider, %{messages: messages}, ^catalog, provider}, 5_000

    assert %{status: :completed, is_error: false, value: value} = List.last(messages).result
    assert value == %{"read" => "pinned file\n", "next" => "following operation\n"}
    assert nested.arguments == %{"path" => "catalog.txt"}
    assert following.arguments == %{"path" => "following.txt"}
    outer = List.last(messages).invocation_id

    for operation <- [nested, following] do
      assert_context(operation, conversation, domain, binding, catalog)
      assert operation.enclosing_invocation_id == outer
      assert operation.invocation_id != outer

      assert Enum.sort(Map.keys(operation.backend_context)) ==
               Enum.sort(Map.keys(direct.backend_context))
    end

    assert length(
             Enum.uniq([direct.invocation_id, nested.invocation_id, following.invocation_id])
           ) ==
             3

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "code-mode-context", %{type: :run_completed}}, 5_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, authority.run_id)
    assert run.state == :completed
    assert run.active_tools == %{}

    for operation <- [direct, nested, following] do
      assert %{is_error: false, text: text} = run.tool_results[operation.invocation_id]

      assert text ==
               if(operation == following, do: "following operation\n", else: "pinned file\n")
    end

    assert map_size(run.tool_results) == 4
    refute_received {:file_read, _}
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp assert_context(operation, owner, domain, binding, catalog) do
    context = operation.backend_context
    assert Map.take(context, Map.keys(domain)) == domain
    assert context.session_binding == binding

    assert Enum.sort(Map.keys(context)) ==
             Enum.sort(Map.keys(domain) ++ [:session_binding | @runtime_keys])

    assert context.cancellation_coordinator == owner
    assert context.resource_owner_pid == owner
    assert context.catalog_snapshot == catalog
    assert operation.catalog_revision == catalog.revision
    assert operation.run_id == binding.run_id
    assert operation.incarnation == binding.run_incarnation
    assert operation.tool_name == "fixture::read_file"
    assert operation.tool_revision == 1

    for key <-
          @runtime_keys -- [:catalog_snapshot, :resource_owner_pid, :cancellation_coordinator] do
      assert is_function(context[key])
    end
  end

  defp call(provider, id, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
         done()
       ]}
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
