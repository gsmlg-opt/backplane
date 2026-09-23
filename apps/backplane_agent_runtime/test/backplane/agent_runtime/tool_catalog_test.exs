Code.require_file("../../fixtures/issue_46_tool_schemas.exs", __DIR__)

defmodule Backplane.AgentRuntime.ToolCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolRegistry}
  alias Backplane.AgentRuntime.Issue46ToolSchemas

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

  test "batch admission quarantines only unsupported schemas and narrows authority" do
    valid = descriptor("read", 1, %{"type" => "object", "properties" => %{}})

    unsupported =
      descriptor("legacy", 2, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    assert {:ok, bundle} =
             ToolCatalog.admit_batch([valid, unsupported],
               mode: :quarantine,
               authority: %{
                 caller: "host",
                 run_id: "run",
                 grants: ["read", "legacy"],
                 tool_revisions: %{"read" => 1, "legacy" => 2}
               },
               tools: [
                 %{name: "read", description: "read", parameters: valid.schema},
                 %{name: "legacy", description: "legacy", parameters: unsupported.schema}
               ]
             )

    assert bundle.accepted == ["read"]
    assert bundle.authority.caller == "host"
    assert bundle.authority.grants == ["read"]

    assert [
             %{
               name: "legacy",
               descriptor_revision: 2,
               error: %Error{class: :unsupported_capability}
             }
           ] = bundle.rejected

    assert Map.has_key?(bundle.registry.tools, "read")
    refute Map.has_key?(bundle.registry.tools, "legacy")
    assert [%{name: "read", parameters: parameters}] = bundle.tools
    assert parameters == valid.schema
  end

  test "quarantine scans complete schemas and preserves accepted schemas verbatim" do
    unsupported_schemas = [
      %{
        "type" => "object",
        "properties" => %{"optional" => %{"$schema" => "https://example.invalid/optional"}}
      },
      %{
        "type" => "object",
        "properties" => %{
          "nested" => %{
            "type" => "object",
            "properties" => %{"value" => %{"$schema" => "https://example.invalid/nested"}}
          }
        }
      },
      %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => %{"$schema" => "https://example.invalid/items"}
          }
        }
      },
      %{
        "type" => "object",
        "oneOf" => [
          %{"properties" => %{"kind" => %{"const" => "used"}}},
          %{"properties" => %{"unused" => %{"$schema" => "https://example.invalid/branch"}}}
        ]
      }
    ]

    for schema <- unsupported_schemas do
      candidate = descriptor("candidate", 1, schema)

      assert {:ok, %{accepted: [], rejected: [%{error: %Error{class: :unsupported_capability}}]}} =
               ToolCatalog.admit_batch([candidate],
                 mode: :quarantine,
                 authority: authority(["candidate"])
               )
    end

    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["read"], "default" => "read"},
        "value" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      },
      "description" => "annotations remain intact"
    }

    candidate = descriptor("read", 1, schema)

    assert {:ok, bundle} =
             ToolCatalog.admit_batch([candidate], authority: authority(["read"]))

    assert bundle.registry.tools["read"].schema == schema
    assert [%{parameters: ^schema}] = bundle.tools
  end

  test "admission options reject unknown keys" do
    assert {:error, %Error{class: :validation, message: "unknown admission option"}} =
             ToolCatalog.admit_batch([], mode: :strict, unexpected: true)
  end

  test "strict admission and legacy catalog validation reject unsupported schemas" do
    unsupported =
      descriptor("read", 1, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    assert {:error, %Error{class: :unsupported_capability}} =
             ToolCatalog.admit_batch([unsupported],
               authority: %{caller: "host", run_id: "run", grants: ["read"], tool_revision: 1}
             )

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, unsupported)

    assert {:error, %Error{class: :unsupported_capability}} =
             ToolCatalog.validate(update(registry, 1, 2), 1, run())
  end

  test "duplicate names fail before filtering and single registration still overwrites" do
    valid = descriptor("same", 1, %{"type" => "object"})

    unsupported =
      descriptor("same", 2, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    for descriptors <- [[valid, unsupported], [unsupported, valid]] do
      assert {:error,
              %Error{class: :validation, message: "admission batch contains duplicate tool names"}} =
               ToolCatalog.admit_batch(descriptors,
                 mode: :quarantine,
                 authority: authority(["same"])
               )
    end

    assert {:ok, first} = ToolRegistry.register(%ToolRegistry{}, valid)
    assert {:ok, overwritten} = ToolRegistry.register(first, unsupported)
    assert overwritten.tools["same"].tool_revision == 2
    assert overwritten.tools["same"].schema == unsupported.schema
  end

  test "quarantine never masks independent descriptor, backend, schema, or authority errors" do
    valid = descriptor("candidate", 1, %{"type" => "object"})

    unsupported =
      descriptor("candidate", 1, %{
        "type" => "object",
        "$schema" => "https://example.invalid/schema"
      })

    missing_backend = Map.put(valid, :backend, Backplane.AgentRuntime.MissingCatalogBackend)

    unsupported_missing_backend =
      Map.put(unsupported, :backend, Backplane.AgentRuntime.MissingCatalogBackend)

    malformed_metadata = put_in(unsupported, [:safety, :read_only], :yes)
    invalid_schema = Map.put(valid, :schema, %{"type" => "object", "required" => "path"})

    assert {:error,
            %Error{
              class: :unsupported_capability,
              message: "registered tool backend is unavailable"
            }} =
             ToolCatalog.admit_batch([missing_backend],
               mode: :quarantine,
               authority: authority(["candidate"])
             )

    assert {:error,
            %Error{
              class: :unsupported_capability,
              message: "registered tool backend is unavailable"
            }} =
             ToolCatalog.admit_batch([unsupported_missing_backend],
               mode: :quarantine,
               authority: authority(["candidate"])
             )

    assert {:error, %Error{class: :validation}} =
             ToolCatalog.admit_batch([malformed_metadata],
               mode: :quarantine,
               authority: authority(["candidate"])
             )

    assert {:error, %Error{class: :validation}} =
             ToolCatalog.admit_batch([invalid_schema],
               mode: :quarantine,
               authority: authority(["candidate"])
             )

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch([unsupported],
               mode: :quarantine,
               authority: authority([])
             )

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch([unsupported],
               mode: :quarantine,
               authority: %{authority(["candidate"]) | caller: ""}
             )

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch([unsupported],
               mode: :quarantine,
               authority: %{authority(["candidate"]) | tool_revision: 2}
             )
  end

  test "empty and all-rejected batches stay empty and repaired revisions can return" do
    assert {:ok, %{accepted: [], tools: [], rejected: [], authority: %{grants: []}}} =
             ToolCatalog.admit_batch([])

    unsupported =
      descriptor("legacy", 1, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    assert {:ok, %{accepted: [], tools: [], authority: %{grants: []}} = quarantined} =
             ToolCatalog.admit_batch([unsupported],
               mode: :quarantine,
               authority: authority(["legacy"])
             )

    assert [%{name: "legacy", descriptor_revision: 1}] = quarantined.rejected

    repaired = descriptor("legacy", 2, %{"type" => "object"})
    repaired_authority = %{authority(["legacy"]) | tool_revision: 2}

    assert {:ok, %{accepted: ["legacy"], rejected: []}} =
             ToolCatalog.admit_batch([repaired],
               mode: :quarantine,
               authority: repaired_authority
             )
  end

  test "per-tool revision authority remains executable and is narrowed with the bundle" do
    read = descriptor("read", 1, %{"type" => "object"})
    write = descriptor("write", 2, %{"type" => "object"})

    unsupported =
      descriptor("legacy", 3, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    authority = %{
      caller: "host",
      run_id: "run",
      grants: ["read", "write", "legacy"],
      tool_revisions: %{"read" => 1, "write" => 2, "legacy" => 3}
    }

    assert {:ok, bundle} =
             ToolCatalog.admit_batch([read, write, unsupported],
               mode: :quarantine,
               authority: authority
             )

    assert bundle.accepted == ["read", "write"]
    assert bundle.authority.grants == ["read", "write"]
    assert bundle.authority.tool_revisions == %{"read" => 1, "write" => 2}
  end

  test "an expected run id rejects mismatched authority before schema quarantine" do
    unsupported =
      descriptor("legacy", 1, %{"type" => "object", "$schema" => "https://example.invalid/schema"})

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch([unsupported],
               mode: :quarantine,
               run_id: "expected-run",
               authority: authority(["legacy"])
             )
  end

  test "provider definitions cannot replace an admitted schema" do
    valid = descriptor("read", 1, %{"type" => "object", "properties" => %{}})

    assert {:error, %Error{class: :resource_conflict}} =
             ToolCatalog.admit_batch(
               %{
                 registry: %ToolRegistry{tools: %{"read" => valid}},
                 authority: %{caller: "host", run_id: "run", grants: ["read"], tool_revision: 1},
                 tools: [%{name: "read", description: "", parameters: %{"type" => "object"}}]
               },
               []
             )
  end

  test "dynamic catalog admission projects the original provider batch and preserves diagnostics" do
    valid = descriptor("read", 1, %{"type" => "object"})

    unsupported =
      descriptor("legacy", 2, %{
        "type" => "object",
        "$schema" => "https://example.invalid/schema"
      })

    {:ok, first} = ToolRegistry.register(%ToolRegistry{}, valid)
    {:ok, registry} = ToolRegistry.register(first, unsupported)

    update = %{
      publication_id: "dynamic-quarantine",
      run_id: "run",
      incarnation: 1,
      expected_revision: 1,
      schema_admission: :quarantine,
      catalog: %{
        revision: 2,
        registry: registry,
        authority: %{
          caller: "host",
          run_id: "run",
          grants: ["read", "legacy"],
          tool_revision: 1,
          tool_revisions: %{"read" => 1, "legacy" => 2}
        },
        tools: [
          %{name: "read", description: "", parameters: valid.schema},
          %{name: "legacy", description: "", parameters: unsupported.schema}
        ]
      }
    }

    assert {:ok, catalog} = ToolCatalog.validate(update, 1, run())
    assert [%{name: "legacy", descriptor_revision: 2}] = catalog.rejected
    assert Map.keys(catalog.registry.tools) == ["read"]
    assert Enum.map(catalog.tools, & &1.name) == ["read"]
    assert catalog.authority.grants == ["read"]
  end

  test "malformed non-map candidates return validation errors" do
    assert {:error, %Error{class: :validation}} =
             ToolCatalog.admit_batch([:bad], authority: %{grants: []})

    descriptor = descriptor("read", 1, %{"type" => "object"})

    assert {:error, %Error{class: :validation}} =
             ToolCatalog.admit_batch(
               %{
                 registry: %ToolRegistry{tools: %{"read" => descriptor}},
                 authority: %{caller: "host", run_id: "run", grants: ["read"], tool_revision: 1},
                 tools: [:bad]
               },
               []
             )
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
        branches ++ [%{"properties" => %{"unused" => %{"$ref" => "#/$defs/unused"}}}]
      end)

    registry = registry("read", 1, unsupported)

    assert {:error, %Error{class: :validation, details: %{reference: "#/$defs/unused"}}} =
             ToolCatalog.validate(update(registry, 1, 2), 1, run())
  end

  test "preflights current MCP schema features before publishing a catalog" do
    registry = registry("read", 1, Issue46ToolSchemas.mixed_inputs())
    assert {:ok, _catalog} = ToolCatalog.validate(update(registry, 1, 2), 1, run())

    unsupported =
      put_in(Issue46ToolSchemas.mixed_inputs(), ["properties", "metadata"], %{
        "$ref" => "#/$defs/metadata"
      })

    registry = registry("read", 1, unsupported)

    assert {:error, %Error{class: :validation, details: %{reference: "#/$defs/metadata"}}} =
             ToolCatalog.validate(update(registry, 1, 2), 1, run())
  end

  test "preflights the captured 58-tool live catalog as one publication" do
    path = Path.expand("../../fixtures/issue_46_live_catalog.json", __DIR__)
    definitions = path |> File.read!() |> JSON.decode!()

    registry =
      definitions
      |> Enum.reduce(%ToolRegistry{}, fn %{"name" => name, "inputSchema" => schema}, registry ->
        {:ok, registry} =
          ToolRegistry.register(registry, %{
            tool_name: name,
            tool_revision: 1,
            schema: schema,
            safety: %{read_only: true, retry_safe: true, parallel_safe: false},
            backend: Backend,
            backend_context: %{}
          })

        registry
      end)

    tools =
      Enum.map(definitions, fn %{"name" => name, "inputSchema" => schema} ->
        %{name: name, description: "", parameters: schema}
      end)

    update = %{
      publication_id: "issue-46-catalog",
      run_id: "run",
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: registry,
        authority: %{
          caller: "host",
          run_id: "run",
          grants: Enum.map(definitions, & &1["name"]),
          tool_revision: 1
        },
        tools: tools
      }
    }

    assert {:ok, _catalog} = ToolCatalog.validate(update, 1, run())
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

    malformed =
      candidate
      |> Map.put(:schema_admission, :quarantine)
      |> Map.put(:run_id, "other")
      |> put_in([:catalog, :registry, Access.key(:tools), "read", :safety], %{})

    assert {:error, %Error{class: :resource_conflict}} =
             ToolCatalog.validate(malformed, 1, %{run_id: "run", incarnation: 1})
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

  defp authority(grants),
    do: %{caller: "host", run_id: "run", grants: grants, tool_revision: 1}

  defp descriptor(name, revision, schema) do
    %{
      tool_name: name,
      tool_revision: revision,
      schema: schema,
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Backend,
      backend_context: %{}
    }
  end
end
