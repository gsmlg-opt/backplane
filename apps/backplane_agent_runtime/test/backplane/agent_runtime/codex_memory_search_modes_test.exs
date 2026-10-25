defmodule Backplane.AgentRuntime.CodexMemorySearchModesTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.{Contract, ExtensionRuntime, Invocation}

  @scope %{host_id: "host", caller_id: "caller", run_id: "memory-search", project_id: "project"}
  @queries ["alpha", "beta"]

  setup do
    runtime =
      start_supervised!(
        {ExtensionRuntime,
         scope: @scope, memories: %{"fixture.md" => "alpha\nseparator\nbeta\nalpha beta\nlast"}}
      )

    raw =
      Enum.find(
        ExtensionRuntime.contracts(%{extension_runtime: runtime}),
        &(&1.namespace == "memories" and &1.name == "search")
      )

    assert {:ok, contract} = Contract.new(raw)
    %{runtime: runtime, contract: contract}
  end

  test "tagged schema admits all pinned modes and rejects strings and malformed windows", ctx do
    for mode <- [
          %{"type" => "any"},
          %{"type" => "all_on_same_line"},
          %{"type" => "all_within_lines", "line_count" => 3}
        ] do
      arguments = %{"queries" => @queries, "match_mode" => mode}

      assert {:ok, %{arguments: ^arguments}} =
               Invocation.decode(%{name: "memories::search", arguments: arguments}, [ctx.contract])
    end

    for mode <- [
          "any",
          "all",
          %{},
          %{"type" => "all"},
          %{"type" => "all_within_lines"},
          %{"type" => "all_within_lines", "line_count" => 0},
          %{"type" => "all_within_lines", "line_count" => -1},
          %{"type" => "all_within_lines", "line_count" => 1.5},
          %{"type" => "any", "line_count" => 2}
        ] do
      assert {:error, %Error{class: :validation}} =
               Invocation.decode(
                 %{
                   name: "memories::search",
                   arguments: %{"queries" => @queries, "match_mode" => mode}
                 },
                 [ctx.contract]
               )
    end
  end

  test "default any, same-line and minimal line windows produce distinct canonical matches",
       ctx do
    assert {:ok, any} = search(ctx.runtime, %{})
    assert any.match_mode == %{"type" => "any"}
    assert Enum.map(any.matches, & &1.match_line_number) == [1, 3, 4]
    assert hd(any.matches).matched_queries == ["alpha"]

    assert {:ok, same_line} =
             search(ctx.runtime, %{"match_mode" => %{"type" => "all_on_same_line"}})

    assert [%{match_line_number: 4, content: "alpha beta", matched_queries: @queries}] =
             same_line.matches

    assert {:ok, narrow} =
             search(ctx.runtime, %{
               "match_mode" => %{"type" => "all_within_lines", "line_count" => 2}
             })

    assert Enum.map(narrow.matches, & &1.match_line_number) == [4]

    assert {:ok, wide} =
             search(ctx.runtime, %{
               "match_mode" => %{"type" => "all_within_lines", "line_count" => 3}
             })

    assert [
             %{match_line_number: 1, content: "alpha\nseparator\nbeta"},
             %{match_line_number: 4, content: "alpha beta"}
           ] = wide.matches

    assert {:ok, huge} =
             search(ctx.runtime, %{
               "match_mode" => %{"type" => "all_within_lines", "line_count" => 1_000_000_000}
             })

    assert huge.matches == wide.matches
  end

  test "window response retains context and stable pagination", ctx do
    args = %{
      "match_mode" => %{"type" => "all_within_lines", "line_count" => 3},
      "context_lines" => 1,
      "max_results" => 1
    }

    assert {:ok, first} = search(ctx.runtime, args)
    assert first.truncated

    assert [%{content_start_line_number: 1, content: "alpha\nseparator\nbeta\nalpha beta"}] =
             first.matches

    assert {:ok, second} = search(ctx.runtime, Map.put(args, "cursor", first.next_cursor))

    assert [
             %{
               match_line_number: 4,
               content_start_line_number: 3,
               content: "beta\nalpha beta\nlast"
             }
           ] = second.matches

    refute second.truncated
    assert second.next_cursor == nil
  end

  test "comparison normalization retains original queries and source text" do
    runtime =
      start_supervised!(
        {ExtensionRuntime, scope: @scope, memories: %{"fixture.md" => "Alpha-BETA"}},
        id: :normalized
      )

    assert {:ok, %{matches: []}} = search(runtime, %{})

    assert {:ok, %{matches: [%{content: "Alpha-BETA", matched_queries: ["alpha beta"]}]}} =
             search(runtime, %{
               "queries" => ["alpha beta"],
               "case_sensitive" => false,
               "normalized" => true
             })

    assert {:error, %Error{class: :validation}} =
             search(runtime, %{"queries" => ["---"], "normalized" => true})
  end

  defp search(runtime, extra) do
    ExtensionRuntime.call(%{
      run_id: @scope.run_id,
      tool_name: "memories::search",
      arguments: Map.merge(%{"queries" => @queries}, extra),
      backend_context: %{runtime: runtime}
    })
  end
end
