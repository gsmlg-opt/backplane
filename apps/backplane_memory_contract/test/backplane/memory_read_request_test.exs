defmodule Backplane.MemoryReadRequestTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryReadRequest

  @id "12345678-1234-4234-8234-123456789abc"

  test "normalizes project consistently and keeps empty recall project unspecified" do
    assert {:ok, "café project"} = MemoryReadRequest.normalize_project("  cafe\u0301\n project  ")
    assert {:ok, nil} = MemoryReadRequest.normalize_project(" \n ")
    assert {:ok, nil} = MemoryReadRequest.normalize_project(nil)

    assert {:ok, %{"query" => "q"}} =
             MemoryReadRequest.validate("recall", %{"query" => "q", "project" => "  "})

    for value <- [<<255>>, 123, String.duplicate("é", 513)] do
      assert {:error, :invalid_arguments} = MemoryReadRequest.normalize_project(value)
    end
  end

  test "get validates UUIDs and normalizes a source association without credentials" do
    assert {:ok, args} =
             MemoryReadRequest.validate("get", %{
               "id" => @id,
               "memory_access_id" => @id,
               "project" => "  café\n project ",
               "source" => %{
                 "repository_id" => "https://secret:token@GitHub.com/org/repo.git",
                 "checkout_root" => "/work/repo",
                 "cwd" => "/work/repo/apps"
               }
             })

    assert args["project"] == "café project"
    assert args["source"]["repository_id"] == "github.com/org/repo"
    assert args["source"]["cwd"] == "/work/repo/apps"
  end

  test "get rejects raw authority, unsupported filters and malformed source values" do
    for args <-
          [
            %{},
            %{"id" => "provisional-123"},
            %{"id" => @id, "memory_access_id" => "bad"},
            %{"id" => @id, "project" => " "},
            %{"id" => @id, "project" => nil},
            %{"id" => @id, "source" => %{}},
            %{"id" => @id, "source" => %{"cwd" => " "}},
            %{"id" => @id, "source" => %{"cwd" => <<255>>}},
            %{"id" => @id, "source" => %{"cwd" => String.duplicate("a", 4097)}},
            %{"id" => @id, "source" => %{"repository_id" => "/local/path"}},
            %{"id" => @id, "source" => %{"unknown" => "x"}}
          ] ++
            Enum.map(
              ~w(scope namespace host_id client_id memory_space_id authority_version query),
              &%{"id" => @id, &1 => "x"}
            ) do
      assert {:error, :invalid_arguments} = MemoryReadRequest.validate("get", args)
    end
  end

  test "recall accepts canonical identity filters and rejects nonstring or unknown selectors" do
    args = %{
      "query" => "query",
      "session_id" => "session-a",
      "agent_id" => "agent-a",
      "tag" => "tag-a"
    }

    assert {:ok, ^args} = MemoryReadRequest.validate("recall", args)

    for key <- ~w(session_id agent_id tag), invalid <- [nil, 1, [], %{}] do
      assert {:error, :invalid_arguments} =
               MemoryReadRequest.validate("recall", Map.put(args, key, invalid))
    end

    assert {:error, :invalid_arguments} =
             MemoryReadRequest.validate("recall", Map.put(args, "unknown_selector", "value"))
  end

  test "recall and list reject schema violations before any fallback" do
    for {method, args} <- [
          {"recall", %{}},
          {"recall", %{"query" => nil}},
          {"recall", %{"query" => "q", "type" => "semantic"}},
          {"recall", %{"query" => "q", "q" => "x"}},
          {"recall", %{"query" => "q", "offset" => 1}},
          {"recall", %{"query" => "q", "limit" => -1}},
          {"recall", %{"query" => "q", "limit" => "10"}},
          {"recall", %{"query" => "q", "facets" => [%{"dimension" => "x"}]}},
          {"recall", %{"query" => "q", "token_budget" => 0}},
          {"recall", %{"query" => "q", "channel_weights" => %{"fts" => "bad"}}},
          {"recall", %{"query" => "q", "temporal_hints" => %{"after" => "yesterday"}}},
          {"recall", %{"query" => "q", "include_working" => nil}},
          {"list", %{"project" => "x"}},
          {"list", %{"facets" => []}},
          {"list", %{"offset" => -1}},
          {"list", %{"limit" => 1.5}},
          {"list", %{"tag" => []}}
        ] do
      assert {:error, :invalid_arguments} = MemoryReadRequest.validate(method, args)
    end

    assert {:ok, %{}} = MemoryReadRequest.validate("list", %{})

    assert {:ok, %{"offset" => 2, "limit" => 50}} =
             MemoryReadRequest.validate("list", %{"offset" => 2, "limit" => 50})

    assert {:ok, _} =
             MemoryReadRequest.validate("recall", %{
               "query" => "q",
               "facets" => [],
               "entity_hints" => [],
               "temporal_hints" => %{},
               "channel_weights" => %{"fts" => 1, "vector" => 0},
               "token_budget" => 100
             })
  end

  test "internal atom read keys normalize without accepting ambiguous duplicate names" do
    assert {:ok, %{"limit" => 200, "offset" => 10}} =
             MemoryReadRequest.validate("list", %{limit: 200, offset: 10})

    assert {:ok, %{"query" => "q", "limit" => 20}} =
             MemoryReadRequest.validate("recall", %{query: "q", limit: 20})

    assert {:error, :invalid_arguments} =
             MemoryReadRequest.validate("list", %{:limit => 20, "limit" => 20})

    assert {:error, :invalid_arguments} =
             MemoryReadRequest.validate("recall", %{query: "q", unknown: true})
  end
end
