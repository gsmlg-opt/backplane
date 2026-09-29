defmodule Backplane.AgentRuntime.CodexContractTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{Catalog, Contract, Invocation, Result}

  defmodule Backend do
    def execute(_operation), do: {:ok, %{content: "ok"}}
  end

  test "namespaced function contracts project through strict catalog admission" do
    assert {:ok, contract} =
             Contract.new(%{
               namespace: "shell",
               name: "echo",
               description: "echo text",
               backend: Backend,
               schema: %{
                 "type" => "object",
                 "properties" => %{"text" => %{"type" => "string"}},
                 "required" => ["text"]
               },
               safety: %{read_only: true, retry_safe: true, parallel_safe: true}
             })

    assert contract.tool_name == "shell::echo"

    assert {:ok, bundle} =
             Catalog.admit(
               [contract],
               %{caller: "host", run_id: "run", grants: ["shell::echo"], tool_revision: 1}
             )

    assert [%{name: "shell::echo", type: "function", parameters: parameters}] = bundle.tools
    assert parameters == contract.schema
    assert bundle.contracts["shell::echo"] == contract
  end

  test "custom calls retain raw input and reject incomplete execution" do
    assert {:ok, contract} =
             Contract.new(%{
               namespace: "code",
               name: "raw",
               input_kind: :custom,
               format: %{"type" => "text"},
               safety: %{read_only: true, retry_safe: true, parallel_safe: true}
             })

    assert {:ok, invocation} =
             Invocation.decode(
               %{id: "call_1", name: "code::raw", arguments: "part-1", complete?: false},
               [contract]
             )

    refute Invocation.complete?(invocation)
    assert invocation.raw_input == "part-1"
    assert {:ok, appended} = Invocation.append_chunk(invocation, "-part-2")
    assert appended.raw_input == "part-1-part-2"
    assert {:ok, finished} = Invocation.finish(appended)
    assert Invocation.complete?(finished)
    assert finished.arguments == "part-1-part-2"

    assert {:error, %Error{class: :resource_conflict}} =
             Invocation.append_chunk(%{appended | complete?: true}, "late")
  end

  test "function calls validate schema and result preserves artifacts" do
    assert {:ok, contract} =
             Contract.new(%{
               name: "read",
               schema: %{"type" => "object", "required" => ["path"]},
               safety: %{read_only: true, retry_safe: true, parallel_safe: true}
             })

    assert {:error, %Error{class: :validation}} =
             Invocation.decode(%{name: "read", arguments: %{}}, [contract])

    assert {:ok, result} =
             Result.success(%{content: "ok", artifacts: [%{type: :image, data: "bytes"}]})

    assert result.artifacts == [%{type: :image, data: "bytes"}]

    assert %{type: :tool_error, error: %{"class" => :validation}} =
             Result.failure(Error.new(:validation, "bad input"))
  end

  test "duplicate canonical names and invalid schemas are rejected" do
    attrs = %{name: "same", safety: %{read_only: true, retry_safe: true, parallel_safe: true}}
    assert {:ok, first} = Contract.new(attrs)
    assert {:ok, second} = Contract.new(Map.put(attrs, :namespace, nil))
    assert {:error, %Error{class: :validation}} = Catalog.admit([first, second])

    assert {:error, %Error{class: :unsupported_capability}} =
             Contract.new(%{
               name: "bad",
               schema: %{"type" => "object", "$schema" => "https://example.invalid"},
               safety: %{read_only: true, retry_safe: true, parallel_safe: true}
             })

    assert {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, Contract.descriptor(first))
    assert {:ok, _} = ToolRegistry.lookup(registry, "same")
  end

  test "Code Mode-only contracts remain authorized but are hidden from the provider" do
    contracts = [
      %{
        name: "exec",
        input_kind: :custom,
        format: %{"type" => "text"},
        backend: Backend,
        safety: %{read_only: false, retry_safe: false, parallel_safe: false}
      },
      %{
        namespace: "mcp",
        name: "echo",
        exposure: :code_mode_only,
        backend: Backend,
        safety: %{read_only: true, retry_safe: true, parallel_safe: true}
      }
    ]

    authority = %{
      caller: "host",
      run_id: "run",
      grants: ["exec", "mcp::echo"],
      tool_revisions: %{"exec" => 1, "mcp::echo" => 1}
    }

    assert {:ok, profile} = Catalog.admit(contracts, authority)
    assert [%{name: "exec"}] = profile.tools
    assert {:ok, _descriptor} = ToolRegistry.lookup(profile.registry, "mcp::echo")
    assert profile.authority.grants |> MapSet.new() == MapSet.new(["exec", "mcp::echo"])
  end
end
