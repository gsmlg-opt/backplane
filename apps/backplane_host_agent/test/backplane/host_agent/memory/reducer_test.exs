defmodule Backplane.HostAgent.Memory.ReducerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Reducer

  test "hashes content as lowercase sha256 hex" do
    assert Reducer.content_hash("remember this") ==
             "8699bdec86f342226a646ca6d61f17cbb024e26a896384d827f46215c1a4bd70"
  end

  test "resolves bound scope and rejects caller scope drift" do
    config = %{bound_scope: "proj_local"}

    assert {:ok, "proj_local"} = Reducer.resolve_scope(%{}, config)
    assert {:ok, "proj_local"} = Reducer.resolve_scope(%{"scope" => "proj_local"}, config)
    assert {:error, :invalid_scope} = Reducer.resolve_scope(%{"scope" => "other"}, config)
  end

  test "normalizes tags and metadata for JSON storage" do
    assert {:ok, facets} =
             Reducer.normalize_facets(%{
               "tags" => [" beta ", "alpha", "alpha", 42, ""],
               "metadata" => %{"topic" => "memory", "count" => 2}
             })

    assert facets.tags == ["alpha", "beta"]
    assert facets.metadata == %{"count" => 2, "topic" => "memory"}
    assert Jason.decode!(facets.tags_json) == ["alpha", "beta"]
    assert Jason.decode!(facets.metadata_json) == %{"count" => 2, "topic" => "memory"}
  end

  test "builds escaped case-folded LIKE patterns" do
    assert Reducer.like_pattern("  100%_Match\\Path  ") == "%100\\%\\_match\\\\path%"
  end

  test "rank merge is deterministic and prefers exact facts before local token hits" do
    rows = [
      %{
        "id" => "local-token",
        "content" => "alpha unrelated beta",
        "scope" => "proj_local",
        "source" => "local",
        "confidence" => 1.0,
        "inserted_at" => "2026-06-17T00:02:00Z",
        "tags" => "[]",
        "metadata" => "{}"
      },
      %{
        "id" => "fact-exact-old",
        "content" => "alpha beta",
        "scope" => "proj_local",
        "source" => "hub_fact",
        "confidence" => 0.5,
        "inserted_at" => "2026-06-17T00:00:00Z",
        "tags" => "[]",
        "metadata" => "{}"
      },
      %{
        "id" => "local-exact-new",
        "content" => "alpha beta",
        "scope" => "proj_local",
        "source" => "local",
        "confidence" => 1.0,
        "inserted_at" => "2026-06-17T00:03:00Z",
        "tags" => "[]",
        "metadata" => "{}"
      }
    ]

    hits = Reducer.rank_hits(rows, "alpha beta", 10)

    assert Enum.map(hits, & &1["id"]) == [
             "fact-exact-old",
             "local-exact-new",
             "local-token"
           ]

    assert Enum.all?(hits, &(&1["quality"] == "degraded"))
  end
end
