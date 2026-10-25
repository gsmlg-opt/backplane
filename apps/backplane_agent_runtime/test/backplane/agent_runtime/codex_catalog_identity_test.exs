defmodule Backplane.AgentRuntime.CodexCatalogIdentityTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Catalog, Contract, Dynamic}

  @name "mcp::8ba06351-9014-4602-9f0c-f5ab45336c22::documents::read"
  @safety %{read_only: true, retry_safe: true, parallel_safe: true}

  defmodule Backend do
    def execute(arguments), do: {:ok, %{arguments: arguments}}
  end

  test "UUID-qualified MCP identity survives parsing, admission, publication and dispatch" do
    assert {:ok, {namespace, name}} = Contract.split_name(@name)
    assert namespace == "mcp"
    assert name == "8ba06351-9014-4602-9f0c-f5ab45336c22::documents::read"

    attrs = %{namespace: namespace, name: name, backend: Backend, safety: @safety}
    assert {:ok, contract} = Contract.new(attrs)
    assert contract.tool_name == @name
    assert Contract.descriptor(contract).tool_name == @name
    assert Contract.provider_definition(contract).name == @name

    authority = %{caller: "host", run_id: "run", grants: [@name], tool_revisions: %{@name => 1}}
    assert {:ok, catalog} = Catalog.admit([contract], authority)
    assert [%{name: @name}] = catalog.tools
    assert catalog.authority.grants == [@name]
    assert catalog.authority.tool_revisions == %{@name => 1}
    assert {:ok, %{tool_name: @name}} = ToolRegistry.lookup(catalog.registry, @name)

    assert {:ok, dynamic} = Dynamic.new()
    assert {:ok, dynamic, [%{name: @name}]} = Dynamic.discover(dynamic, "run", [attrs])
    assert {:ok, [%{name: @name}]} = Dynamic.search(dynamic, "run", "documents")
    assert {:ok, dynamic, _} = Dynamic.publish(dynamic, "run", @name, authority)
    assert {:ok, _, snapshot} = Dynamic.snapshot(dynamic, "run")

    assert {:ok, _, %{arguments: %{"key" => "value"}}} =
             Dynamic.call(dynamic, snapshot, "run", @name, %{"key" => "value"})

    assert {:error, %Error{class: :forbidden}} =
             Dynamic.call(dynamic, snapshot, "other", @name, %{})
  end

  test "namespace separators are confined to the local remainder" do
    assert {:error, %Error{class: :validation}} =
             Contract.new(%{namespace: "mcp::source", name: "read", safety: @safety})

    for canonical <- ["read", "mcp::source::read", "mcp::source::raw::read"] do
      assert {:ok, {namespace, name}} = Contract.split_name(canonical)
      assert {:ok, contract} = Contract.new(%{namespace: namespace, name: name, safety: @safety})
      assert contract.tool_name == canonical
    end
  end

  test "direct-model-only contracts retain direct definitions and exact authority" do
    for exposure <- [:direct_model_only, "direct_model_only"] do
      assert {:ok, contract} =
               Contract.new(%{
                 name: "history",
                 exposure: exposure,
                 backend: Backend,
                 safety: @safety
               })

      authority = %{caller: "host", run_id: "run", grants: ["history"], tool_revision: 1}
      assert {:ok, catalog} = Catalog.admit([contract], authority)
      assert [%{name: "history"}] = catalog.tools
      assert catalog.authority.grants == ["history"]
      assert catalog.registry.tools["history"].codex_exposure == :direct_model_only
      assert ToolCatalog.provider_visible?(Contract.descriptor(contract))
    end
  end

  test "catalog refresh compares provider membership separately from complete grants" do
    contracts =
      Enum.map([:direct, :direct_model_only, :code_mode_only, :deferred, :hidden], fn exposure ->
        %{name: Atom.to_string(exposure), exposure: exposure, backend: Backend, safety: @safety}
      end)

    names = Enum.map(contracts, & &1.name)
    authority = %{caller: "host", run_id: "run", grants: names, tool_revision: 1}
    assert {:ok, bundle} = Catalog.admit(contracts, authority)

    update = %{
      run_id: "run",
      incarnation: 1,
      expected_revision: 1,
      publication_id: "visible-refresh",
      catalog: %{
        revision: 2,
        registry: bundle.registry,
        authority: bundle.authority,
        tools: bundle.tools
      }
    }

    assert {:ok, refreshed} = ToolCatalog.validate(update, 1, %{run_id: "run", incarnation: 1})
    assert Enum.sort(Enum.map(refreshed.tools, & &1.name)) == ["direct", "direct_model_only"]
    assert MapSet.new(refreshed.authority.grants) == MapSet.new(names)
    initial = ToolCatalog.initial(registry: bundle.registry, authority: bundle.authority)
    assert Enum.sort(Enum.map(initial.tools, & &1.name)) == ["direct", "direct_model_only"]

    leaked =
      Map.update!(
        update.catalog,
        :tools,
        &(&1 ++ [Contract.provider_definition(bundle.contracts["hidden"])])
      )

    assert {:error, %Error{class: :validation}} =
             ToolCatalog.validate(%{update | catalog: leaked}, 1, %{run_id: "run", incarnation: 1})

    invalid = put_in(update, [:catalog, :registry, Access.key(:tools), "hidden", :backend], nil)

    assert {:error, %Error{class: :unsupported_capability}} =
             ToolCatalog.validate(invalid, 1, %{run_id: "run", incarnation: 1})
  end
end
