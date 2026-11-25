defmodule Backplane.Hub.DiscoverTest do
  use BackplaneMcp.DataCase, async: false

  alias Backplane.Hub.Discover
  alias Backplane.Skills.{Registry, Skill}

  setup do
    # Insert a skill for search
    content = "# Elixir GenServer patterns and best practices"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: "disc/elixir",
      slug: "disc-elixir",
      name: "Elixir Patterns",
      description: "Design patterns for Elixir",
      tags: ["elixir"],
      content: content,
      content_hash: hash,
      source: "db",
      enabled: true
    })
    |> Repo.insert!()

    if :ets.whereis(:backplane_skills) != :undefined do
      Registry.refresh()
    end

    Backplane.Registry.ToolRegistry.register_managed("discovery", [
      %{
        name: "discovery::sample",
        description: "A test tool",
        input_schema: %{},
        handler: fn args -> {:ok, args} end
      }
    ])

    on_exit(fn -> Backplane.Registry.ToolRegistry.deregister_managed("discovery") end)
    :ok
  end

  describe "search/2" do
    test "returns results across tools and skills" do
      {:ok, results} = Discover.search("elixir")
      assert is_list(results.tools)
      assert is_list(results.skills)
    end

    test "scopes to tools only when scope: [tools]" do
      {:ok, results} = Discover.search("discovery", scope: ["tools"])
      assert results.tools != []
      assert results.skills == []
    end

    test "scopes to skills only when scope: [skills]" do
      {:ok, results} = Discover.search("elixir", scope: ["skills"])
      assert results.tools == []
      assert results.skills != []
    end

    test "limits results per scope" do
      {:ok, results} = Discover.search("discovery", scope: ["tools"], limit: 1)
      assert length(results.tools) <= 1
    end

    test "returns empty groups for no matches" do
      {:ok, results} = Discover.search("zzzznonexistent999")
      assert results.tools == []
      assert results.skills == []
    end

    test "handles missing engines gracefully" do
      {:ok, results} = Discover.search("anything")
      assert is_map(results)
      assert Map.has_key?(results, :tools)
      assert Map.has_key?(results, :skills)
    end
  end
end
