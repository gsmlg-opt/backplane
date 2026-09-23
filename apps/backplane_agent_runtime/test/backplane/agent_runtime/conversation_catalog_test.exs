defmodule Backplane.AgentRuntime.ConversationCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolRegistry}

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

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool, operation, self()})

      receive do
        {:capture_stager, update, result} ->
          stager = operation.backend_context.stage_catalog
          send(operation.backend_context.test, {:captured_stager, stager})
          receipt = stager.(update)
          send(operation.backend_context.test, {:stage_receipt, receipt})
          result

        {:stage, update, result} ->
          receipt = operation.backend_context.stage_catalog.(update)
          send(operation.backend_context.test, {:stage_receipt, receipt})
          result

        {:result, result} ->
          result

        :interact ->
          answer = operation.backend_context.interact.(%{kind: :permission})
          send(operation.backend_context.test, {:interaction_answer, answer})
          {:ok, %{text: "answered"}}
      end
    end
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      kind = elem(meta.command, 0)

      cond do
        kind == Map.get(context, :fail_on) ->
          {:error, Error.new(:execution_failure, "injected catalog boundary failure")}

        kind == Map.get(context, :gate_on) ->
          send(context.test, {:commit_waiting, self()})

          receive do
            :commit -> EphemeralStore.store(context.table, run, meta)
          end

        true ->
          EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "publishes after a pinned batch and dispatches the discovered tool exactly once" do
    {pid, store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "discover")

    assert_receive {:provider, first_request, first_provider}
    assert first_request.catalog_revision == 1
    assert Enum.map(first_request.tools, & &1.name) == ["discover"]

    send(first_provider, {:events, [call("d1", "discover"), call("n1", "new"), done("batch")]})
    assert_receive {:tool, %{tool_name: "discover", catalog_revision: 1}, discovery}
    send(discovery, {:stage, update, {:ok, %{text: "found"}}})
    assert_receive {:stage_receipt, {:ok, %{status: :staged, catalog_revision: 2}}}

    refute_receive {:tool, %{tool_name: "new"}, _}, 20
    assert_receive {:provider, second_request, second_provider}
    assert second_request.catalog_revision == 2
    assert Enum.map(second_request.tools, & &1.name) == ["discover", "new"]
    assert List.last(second_request.messages).result.is_error == true

    send(second_provider, {:events, [call("n2", "new"), done("use new")]})
    assert_receive {:tool, %{tool_name: "new", catalog_revision: 2} = operation, new_tool}
    assert operation.effective_authority.grants == ["discover", "new"]
    assert operation.effective_authority.credential == "catalog-secret"
    assert operation.backend_context.credential == "backend-secret"
    refute_receive {:tool, %{tool_name: "new"}, _}, 20
    send(new_tool, {:result, {:ok, %{text: "new result"}}})

    assert_receive {:provider, %{catalog_revision: 2}, final_provider}

    assert {:ok, record} = EphemeralStore.load(store, "run")

    tool_authorities =
      record.run.execution_intents
      |> Map.values()
      |> Enum.filter(&(&1.type == :tool))
      |> Enum.map(& &1.operation.effective_authority)

    assert tool_authorities != []
    assert Enum.all?(tool_authorities, &(not Map.has_key?(&1, :grants)))
    assert Enum.all?(tool_authorities, &(not Map.has_key?(&1, :credential)))
    refute inspect(record) =~ "catalog-secret"
    refute inspect(record) =~ "backend-secret"

    send(final_provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}

    status = Conversation.status(pid)
    assert status.catalog_revision == 2

    assert status.catalog_publication == %{
             publication_id: "catalog-2",
             catalog_revision: 2,
             status: :published
           }

    assert {:ok, %{status: :published}} = Conversation.stage_catalog(pid, update)
  end

  test "reconciles a lost staging acknowledgement and rejects conflicting publication ids" do
    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "discover")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}

    caller =
      spawn(fn ->
        _ignored_receipt = Conversation.stage_catalog(pid, update)
      end)

    monitor = Process.monitor(caller)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert {:ok, %{status: :staged}} = Conversation.stage_catalog(pid, update)

    conflict = put_in(update, [:catalog, :tools, Access.at(0), :description], "changed")

    assert {:error, %Error{class: :resource_conflict}} =
             Conversation.stage_catalog(pid, conflict)

    send(discovery, {:result, {:ok, %{text: "done"}}})
    assert_receive {:provider, _, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}
  end

  test "quarantine publication keeps rejected tools out of old and new snapshots" do
    {pid, _store, update} = start()

    unsupported = %{
      tool_name: "legacy",
      tool_revision: 1,
      description: "legacy tool",
      schema: %{"type" => "object", "$schema" => "https://example.invalid/legacy"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{test: self()}
    }

    {:ok, revised} = ToolRegistry.register(update.catalog.registry, unsupported)

    quarantine =
      update
      |> Map.put(:schema_admission, :quarantine)
      |> put_in([:catalog, :registry], revised)
      |> update_in([:catalog, :authority, :grants], &(&1 ++ ["legacy"]))
      |> put_in([:catalog, :tools], definitions(revised))

    {:ok, _} = Conversation.prompt(pid, "discover")
    assert_receive {:provider, %{catalog_revision: 1}, provider}

    send(provider, {
      :events,
      [call("d1", "discover"), call("l1", "legacy"), done("old batch")]
    })

    assert_receive {:tool, %{tool_name: "discover", catalog_revision: 1}, discovery}
    send(discovery, {:stage, quarantine, {:ok, %{text: "found"}}})
    assert_receive {:stage_receipt, {:ok, %{status: :staged, catalog_revision: 2}}}
    refute_receive {:tool, %{tool_name: "legacy"}, _}, 20

    assert_receive {:provider, %{catalog_revision: 2, tools: tools}, next}
    assert Enum.map(tools, & &1.name) == ["discover", "new"]

    changed_schema = %{"type" => "object", "$schema" => "https://example.invalid/changed"}

    conflicting =
      quarantine
      |> put_in(
        [:catalog, :registry, Access.key(:tools), "legacy", :schema],
        changed_schema
      )
      |> update_in([:catalog, :tools], fn tools ->
        Enum.map(tools, fn
          %{name: "legacy"} = tool -> %{tool | parameters: changed_schema}
          tool -> tool
        end)
      end)

    assert {:error,
            %Error{
              class: :resource_conflict,
              message: "publication id was already used for another catalog"
            }} =
             Conversation.stage_catalog(pid, conflicting)

    send(next, {:events, [call("l2", "legacy"), done("hallucinated")]})
    refute_receive {:tool, %{tool_name: "legacy"}, _}, 20
    assert_receive {:provider, %{catalog_revision: 2}, final_provider}
    send(final_provider, {:events, [done("complete")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}
  end

  test "a stale injected effect token cannot reconcile an existing receipt" do
    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "discover")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}
    send(discovery, {:capture_stager, update, {:ok, %{text: "done"}}})
    assert_receive {:captured_stager, stager}
    assert_receive {:stage_receipt, {:ok, %{status: :staged}}}
    assert_receive {:provider, %{catalog_revision: 2}, next}

    assert {:error, %Error{class: :resource_conflict}} = stager.(update)
    assert {:ok, %{status: :published}} = Conversation.stage_catalog(pid, update)

    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}
  end

  test "failed or error-marked discovery and cancellation discard staging" do
    for result <- [
          {:error, "failed"},
          {:ok, %{is_error: true, error: "failed"}},
          {:ok, %{"is_error" => true, "error" => "failed"}}
        ] do
      {pid, _store, update} = start()
      {:ok, _} = Conversation.prompt(pid, "discover")
      assert_receive {:provider, _, provider}
      send(provider, {:events, [call("d1", "discover"), done("discover")]})
      assert_receive {:tool, _, discovery}
      send(discovery, {:stage, update, result})
      assert_receive {:stage_receipt, {:ok, %{status: :staged}}}
      assert_receive {:provider, %{catalog_revision: 1}, next}
      send(next, {:events, [done("done")]})
      assert_receive {:agent_runtime, "run", %{type: :run_completed}}
      assert Conversation.status(pid).catalog_revision == 1
      assert {:error, %Error{class: :resource_conflict}} = Conversation.stage_catalog(pid, update)
    end

    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "cancel")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, _discovery}
    assert {:ok, %{status: :staged}} = Conversation.stage_catalog(pid, update)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "run", %{type: :run_cancelled}}
    assert Conversation.status(pid).catalog_revision == 1
    assert {:error, %Error{class: :resource_conflict}} = Conversation.stage_catalog(pid, update)
  end

  test "rejects staging during approval or interaction and fences incarnation first" do
    {pid, _store, update} = start(requires_approval: true)
    {:ok, _} = Conversation.prompt(pid, "approve")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:agent_runtime, "run", %{type: :interaction_requested, interaction_id: id}}

    assert {:error, %Error{class: :resource_conflict}} = Conversation.stage_catalog(pid, update)

    changed_incarnation = %{update | incarnation: 2}

    assert {:error, %Error{class: :resource_conflict}} =
             Conversation.stage_catalog(pid, changed_incarnation)

    assert :ok = Conversation.resolve(pid, id, :denied)
    assert_receive {:provider, _, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}

    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "interact")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}
    send(discovery, :interact)
    assert_receive {:agent_runtime, "run", %{type: :interaction_requested, interaction_id: id}}
    assert {:error, %Error{class: :resource_conflict}} = Conversation.stage_catalog(pid, update)
    assert :ok = Conversation.resolve(pid, id, :allow)
    assert_receive {:interaction_answer, {:ok, :allow}}
  end

  test "stale revisions, competing publications, changed incarnation, and invalid schemas are atomic" do
    for invalid_update <- [
          fn update -> %{update | publication_id: "stale", expected_revision: 2} end,
          fn update -> %{update | publication_id: "other", incarnation: 2} end,
          fn update ->
            schema = %{"type" => "object", "description" => self()}

            update
            |> put_in([:publication_id], "invalid-schema")
            |> put_in([:catalog, :registry, Access.key(:tools), "discover", :schema], schema)
            |> put_in([:catalog, :tools, Access.at(0), :parameters], schema)
          end,
          fn update ->
            update
            |> Map.put(:publication_id, "fatal-after-accepted")
            |> Map.put(:schema_admission, :quarantine)
            |> put_in(
              [:catalog, :registry, Access.key(:tools), "new", :backend],
              Backplane.AgentRuntime.MissingCatalogBackend
            )
          end
        ] do
      {pid, _store, update} = start()
      {:ok, _} = Conversation.prompt(pid, "invalid")
      assert_receive {:provider, _, provider}
      send(provider, {:events, [call("d1", "discover"), done("discover")]})
      assert_receive {:tool, _, discovery}

      assert {:error, %Error{}} = Conversation.stage_catalog(pid, invalid_update.(update))
      assert Conversation.status(pid).catalog_revision == 1
      assert Conversation.status(pid).pending_catalog_publication == nil

      send(discovery, {:result, {:ok, %{text: "done"}}})
      assert_receive {:provider, %{catalog_revision: 1}, next}
      send(next, {:events, [done("done")]})
      assert_receive {:agent_runtime, "run", %{type: :run_completed}}
    end

    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "competing")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}
    assert {:ok, %{status: :staged}} = Conversation.stage_catalog(pid, update)

    competing = %{update | publication_id: "competing-publication"}

    assert {:error, %Error{class: :resource_conflict}} =
             Conversation.stage_catalog(pid, competing)

    assert Conversation.status(pid).pending_catalog_publication.publication_id == "catalog-2"
    send(discovery, {:result, {:ok, %{text: "done"}}})
    assert_receive {:provider, %{catalog_revision: 2}, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}
  end

  test "a staged catalog waits for an old-catalog approval and keeps its exact scope" do
    {pid, _store, update} =
      start(initial_names: ["discover", "old"], approval_tools: ["old"])

    {:ok, _} = Conversation.prompt(pid, "discover then approve")
    assert_receive {:provider, %{catalog_revision: 1}, provider}

    send(provider, {
      :events,
      [call("d1", "discover"), call("o1", "old"), done("batch")]
    })

    assert_receive {:tool, %{tool_name: "discover", catalog_revision: 1}, discovery}
    send(discovery, {:stage, update, {:ok, %{text: "found"}}})
    assert_receive {:stage_receipt, {:ok, %{status: :staged}}}

    assert_receive {:agent_runtime, "run",
                    %{
                      type: :interaction_requested,
                      interaction_id: id,
                      request: %{operation: approval_operation}
                    }}

    assert approval_operation.tool_name == "old"
    assert approval_operation.catalog_revision == 1
    assert Conversation.status(pid).catalog_revision == 1
    assert Conversation.status(pid).pending_catalog_publication.status == :staged
    refute_receive {:tool, %{tool_name: "old"}, _}, 20

    assert :ok = Conversation.resolve(pid, id, :approved)
    assert_receive {:tool, %{tool_name: "old", catalog_revision: 1}, old_tool}
    send(old_tool, {:result, {:ok, %{text: "approved"}}})
    assert_receive {:provider, %{catalog_revision: 2}, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}
  end

  test "cancellation while the batch completion checkpoint is gated never publishes" do
    {:ok, table} = EphemeralStore.new(1)

    {pid, _store, update} =
      start(
        store: GatedStore,
        context: %{table: table, test: self(), gate_on: :tool_completed}
      )

    {:ok, _} = Conversation.prompt(pid, "cancel boundary")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}
    send(discovery, {:stage, update, {:ok, %{text: "done"}}})
    assert_receive {:stage_receipt, {:ok, %{status: :staged}}}
    assert_receive {:commit_waiting, commit_worker}
    assert :ok = Conversation.cancel(pid)
    send(commit_worker, :commit)
    assert_receive {:agent_runtime, "run", %{type: :run_cancelled}}
    assert Conversation.status(pid).catalog_revision == 1
    assert Conversation.status(pid).pending_catalog_publication == nil
  end

  test "invalid bundles and failed boundary checkpoints leave the old catalog active" do
    {pid, _store, update} = start()
    {:ok, _} = Conversation.prompt(pid, "invalid")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}

    invalid = put_in(update, [:catalog, :authority, :grants], ["discover"])
    assert {:error, %Error{}} = Conversation.stage_catalog(pid, invalid)
    assert Conversation.status(pid).catalog_revision == 1
    send(discovery, {:result, {:ok, %{text: "done"}}})
    assert_receive {:provider, %{catalog_revision: 1}, next}
    send(next, {:events, [done("done")]})
    assert_receive {:agent_runtime, "run", %{type: :run_completed}}

    {:ok, table} = EphemeralStore.new(1)

    {pid, _store, update} =
      start(store: GatedStore, context: %{table: table, fail_on: :tool_completed})

    {:ok, _} = Conversation.prompt(pid, "storage")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [call("d1", "discover"), done("discover")]})
    assert_receive {:tool, _, discovery}
    send(discovery, {:stage, update, {:ok, %{text: "done"}}})
    assert_receive {:stage_receipt, {:ok, %{status: :staged}}}
    assert_receive {:agent_runtime, "run", %{type: :storage_failed}}
    assert Conversation.status(pid).catalog_revision == 1
    assert Conversation.status(pid).pending_catalog_publication == nil
  end

  defp start(opts \\ []) do
    {:ok, store} = EphemeralStore.new(1)
    test = self()
    initial_names = Keyword.get(opts, :initial_names, ["discover"])

    approval_tools =
      if Keyword.get(opts, :requires_approval, false),
        do: initial_names,
        else: Keyword.get(opts, :approval_tools, [])

    initial = registry(initial_names, test, approval_tools)
    revised = registry(Enum.uniq(initial_names ++ ["new"]), test, approval_tools)

    runtime_opts =
      Keyword.merge(
        [
          run_id: "run",
          incarnation: 1,
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: test},
          subscriber: test,
          registry: initial,
          authority: authority(initial_names),
          catalog_revision: 1,
          work: 20,
          run_timeout: 5_000
        ],
        Keyword.drop(opts, [:initial_names, :approval_tools, :requires_approval])
      )

    pid = start_supervised!({Conversation, runtime_opts}, id: make_ref())

    update = %{
      publication_id: "catalog-2",
      run_id: "run",
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: revised,
        authority: authority(Enum.uniq(initial_names ++ ["new"])),
        tools: definitions(revised)
      }
    }

    {pid, store, update}
  end

  defp registry(names, test, approval_tools) do
    Enum.reduce(names, %ToolRegistry{}, fn name, registry ->
      {:ok, registry} =
        ToolRegistry.register(registry, %{
          tool_name: name,
          tool_revision: 1,
          description: "#{name} tool",
          schema: %{"type" => "object", "properties" => %{}},
          safety: %{
            read_only: true,
            retry_safe: true,
            parallel_safe: false,
            requires_approval: name in approval_tools
          },
          backend: Backend,
          backend_context: %{test: test, credential: "backend-secret"}
        })

      registry
    end)
  end

  defp definitions(registry) do
    registry.tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, descriptor} ->
      %{name: name, description: descriptor.description, parameters: descriptor.schema}
    end)
  end

  defp authority(grants),
    do: %{
      caller: "host",
      run_id: "run",
      grants: grants,
      tool_revision: 1,
      credential: "catalog-secret"
    }

  defp call(id, name),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: %{}}}

  defp done(content),
    do: %{type: :response_completed, message: %{role: :assistant, content: content}}
end
