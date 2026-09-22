defmodule Backplane.AgentRuntime.ToolCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolRegistry}

  defmodule Backend do
    def execute(_operation), do: {:ok, %{text: "ok"}}
  end

  test "validates a complete catalog without coupling catalog and descriptor revisions" do
    registry = registry("read", 7)

    update = update(registry, 1, 2)

    assert {:ok, catalog} = ToolCatalog.validate(update, 1, %{run_id: "run", incarnation: 1})
    assert catalog.revision == 2
    assert catalog.registry == registry
    assert catalog.authority.tool_revision == 7
  end

  test "preflights oneOf object composition before publishing a catalog" do
    schema = %{
      "type" => "object",
      "properties" => %{"kind" => %{"type" => "string"}},
      "required" => ["kind"],
      "additionalProperties" => false,
      "oneOf" => [%{"properties" => %{"kind" => %{"type" => "string"}}}]
    }

    registry = registry("read", 1, schema)
    assert {:ok, _catalog} = ToolCatalog.validate(update(registry, 1, 2), 1, run())

    unsupported =
      update_in(schema, ["oneOf"], fn branches ->
        branches ++ [%{"properties" => %{"unused" => %{"pattern" => "unused"}}}]
      end)

    registry = registry("read", 1, unsupported)

    assert {:error, %Error{class: :unsupported_capability, details: %{keyword: "pattern"}}} =
             ToolCatalog.validate(update(registry, 1, 2), 1, run())
  end

  test "rejects malformed forged registries, descriptors, schemas, and definitions" do
    valid = registry("read", 1)

    invalid = [
      put_in(update(valid, 1, 2), [:catalog, :registry], %ToolRegistry{tools: :invalid}),
      put_in(update(valid, 1, 2), [:catalog, :registry], %ToolRegistry{tools: %{"read" => :bad}}),
      put_in(
        update(valid, 1, 2),
        [:catalog, :registry, Access.key(:tools), "read", :safety],
        %{}
      ),
      put_in(
        update(valid, 1, 2),
        [:catalog, :registry, Access.key(:tools), "read", :backend_context],
        :secret
      ),
      put_in(
        update(valid, 1, 2),
        [:catalog, :registry, Access.key(:tools), "read", :schema],
        %{{:invalid, :key} => true}
      ),
      put_in(
        update(valid, 1, 2),
        [:catalog, :registry, Access.key(:tools), "read", :schema],
        %{"type" => "object", "description" => self()}
      ),
      put_in(
        update(valid, 1, 2),
        [:catalog, :registry, Access.key(:tools), "read", :backend],
        Backplane.AgentRuntime.UnavailableCatalogBackend
      ),
      put_in(update(valid, 1, 2), [:catalog, :tools, Access.at(0), :parameters], %{
        "type" => "object"
      }),
      put_in(update(valid, 1, 2), [:catalog, :authority, :grants], [])
    ]

    for candidate <- invalid do
      assert {:error, %Error{}} =
               ToolCatalog.validate(candidate, 1, %{run_id: "run", incarnation: 1})
    end
  end

  test "fences run and incarnation before catalog validation" do
    candidate = update(registry("read", 1), 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             ToolCatalog.validate(%{candidate | run_id: "other"}, 1, %{
               run_id: "run",
               incarnation: 1
             })

    assert {:error, %Error{class: :resource_conflict}} =
             ToolCatalog.validate(%{candidate | incarnation: 2}, 1, %{
               run_id: "run",
               incarnation: 1
             })
  end

  defp update(registry, expected, revision) do
    descriptor = registry.tools["read"]

    %{
      publication_id: "publication",
      run_id: "run",
      incarnation: 1,
      expected_revision: expected,
      catalog: %{
        revision: revision,
        registry: registry,
        authority: %{
          caller: "host",
          run_id: "run",
          grants: ["read"],
          tool_revision: descriptor.tool_revision
        },
        tools: [
          %{name: "read", description: "", parameters: descriptor.schema}
        ]
      }
    }
  end

  defp registry(name, revision, schema \\ %{"type" => "object", "properties" => %{}}) do
    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: name,
        tool_revision: revision,
        schema: schema,
        safety: %{read_only: true, retry_safe: true, parallel_safe: false},
        backend: Backend,
        backend_context: %{}
      })

    registry
  end

  defp run, do: %{run_id: "run", incarnation: 1}
end
