defmodule Backplane.Skills.SearchRerankingTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Search

  setup do
    for {name, desc, tags, attrs} <- [
          {"elixir-genserver", "Guide to GenServer patterns in Elixir", ["elixir", "otp"],
           [
             version: "1.0.0",
             license: "Apache-2.0",
             homepage: "https://example.com/genserver",
             archive_ref:
               "sha256/1111111111111111111111111111111111111111111111111111111111111111.tar.gz",
             size_bytes: 1024,
             file_count: 2
           ]},
          {"elixir-supervisor", "Supervision tree design for Elixir apps", ["elixir", "otp"],
           [
             version: "1.1.0",
             license: "MIT",
             homepage: "https://example.com/supervisor",
             archive_ref:
               "sha256/2222222222222222222222222222222222222222222222222222222222222222.tar.gz",
             size_bytes: 2048,
             file_count: 3
           ]},
          {"phoenix-liveview", "LiveView components and hooks", ["elixir", "phoenix"],
           [
             version: "2.0.0",
             license: "MIT",
             homepage: "https://example.com/liveview",
             archive_ref:
               "sha256/3333333333333333333333333333333333333333333333333333333333333333.tar.gz",
             size_bytes: 4096,
             file_count: 5
           ]}
        ] do
      Backplane.Fixtures.insert_skill(
        Keyword.merge(
          [
            name: name,
            description: desc,
            tags: tags,
            content: "# #{name}\n\n#{desc}\n\nDetailed content about #{Enum.join(tags, ", ")}."
          ],
          attrs
        )
      )
    end

    :ok
  end

  describe "query/2 deterministic v1 behavior" do
    test "returns metadata-only results without embedding fields" do
      results = Search.query("Elixir GenServer")
      assert length(results) > 0

      for result <- results do
        assert Map.has_key?(result, :slug)
        assert Map.has_key?(result, :content_hash)
        assert Map.has_key?(result, :archive_ref)
        assert Map.has_key?(result, :size_bytes)
        assert Map.has_key?(result, :file_count)
        refute Map.has_key?(result, :content)
        refute Map.has_key?(result, :embedding)
      end
    end

    test "ignores stale rerank option and returns the same deterministic result set" do
      default_results = Search.query("Elixir")
      rerank_disabled_results = Search.query("Elixir", rerank: false)

      default_ids = Enum.map(default_results, & &1.id) |> MapSet.new()
      rerank_disabled_ids = Enum.map(rerank_disabled_results, & &1.id) |> MapSet.new()

      assert default_ids == rerank_disabled_ids
    end
  end
end
