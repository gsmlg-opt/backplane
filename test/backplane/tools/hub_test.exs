defmodule Backplane.Tools.HubTest do
  use Backplane.DataCase, async: false

  alias Backplane.Skills.{Registry, Skill}
  alias Backplane.Tools.Hub

  setup do
    content = "# Test skill content"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: "hub/s1",
      name: "Hub Test Skill",
      description: "A skill for hub testing",
      tags: ["test"],
      content: content,
      content_hash: hash,
      source: "db",
      enabled: true
    })
    |> Repo.insert!()

    if :ets.whereis(:backplane_skills) != :undefined do
      Registry.refresh()
    end

    # Ensure native tools are registered in the tool registry
    if :ets.whereis(:backplane_tools) != :undefined do
      alias Backplane.Registry.{Tool, ToolRegistry}

      for module <- [
            Backplane.Tools.Skill,
            Backplane.Tools.Docs,
            Backplane.Tools.Git,
            Backplane.Tools.Hub
          ],
          tool_def <- module.tools() do
        tool = %Tool{
          name: tool_def.name,
          description: tool_def.description,
          input_schema: tool_def.input_schema,
          origin: :native,
          module: tool_def.module,
          handler: tool_def.handler
        }

        ToolRegistry.register_native(tool)
      end
    end

    :ok
  end

  describe "hub::discover" do
    test "returns grouped results matching query" do
      {:ok, results} = Hub.call(%{"_handler" => "discover", "query" => "skill"})
      assert is_map(results)
      assert Map.has_key?(results, :tools)
      assert Map.has_key?(results, :skills)
    end

    test "respects scope filter" do
      {:ok, results} =
        Hub.call(%{"_handler" => "discover", "query" => "skill", "scope" => ["tools"]})

      assert results.skills == []
    end

    test "respects limit" do
      {:ok, results} = Hub.call(%{"_handler" => "discover", "query" => "skill", "limit" => 1})
      assert length(results.tools) <= 1
    end
  end

  describe "hub::inspect" do
    test "returns full schema for native tool" do
      {:ok, result} = Hub.call(%{"_handler" => "inspect", "tool_name" => "skill::search"})
      assert result.name == "skill::search"
      assert is_map(result.input_schema)
      assert result.origin == "native"
    end

    test "returns error for unknown tool" do
      {:error, msg} = Hub.call(%{"_handler" => "inspect", "tool_name" => "nonexistent::tool"})
      assert String.contains?(msg, "Unknown tool")
    end
  end

  describe "hub::status" do
    test "returns upstream connection statuses" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.upstreams)
    end

    test "returns skill source summaries" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.skill_sources)
    end

    test "returns doc project summaries" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_list(result.doc_projects)
    end

    test "returns total tool count" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_integer(result.total_tools)
      assert result.total_tools > 0
    end

    test "returns total skill count" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert is_integer(result.total_skills)
    end

    test "doc_projects includes chunk counts" do
      Repo.insert!(
        %Backplane.Docs.Project{
          id: "hub-status-proj",
          repo: "https://github.com/t/r.git",
          ref: "main"
        },
        on_conflict: :nothing
      )

      Repo.insert!(%Backplane.Docs.DocChunk{
        project_id: "hub-status-proj",
        source_path: "lib/mod.ex",
        content: "content",
        chunk_type: "module_doc",
        content_hash: "hubstatus1"
      })

      {:ok, result} = Hub.call(%{"_handler" => "status"})
      proj = Enum.find(result.doc_projects, &(&1.id == "hub-status-proj"))
      assert proj
      assert proj.chunk_count >= 1
    end

    test "skill_sources groups by source" do
      {:ok, result} = Hub.call(%{"_handler" => "status"})
      assert Enum.any?(result.skill_sources, fn s -> s.name == "db" end)
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler" do
      {:error, msg} = Hub.call(%{"_handler" => "unknown"})
      assert msg =~ "Unknown hub tool handler"
    end

    test "returns error for missing handler" do
      {:error, msg} = Hub.call(%{})
      assert msg =~ "Unknown hub tool handler"
    end
  end
end
