defmodule Backplane.Transport.PromptGetTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{Registry, Skill}

  setup do
    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    :ok
  end

  test "stored skill content is unavailable through MCP prompts" do
    content = "# Prompt Skill\nUse this body as prompt content."
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: "prompt/full-entry",
      slug: "prompt-full-entry",
      name: "full-entry-prompt",
      description: "Prompt backed by a full skill fetch",
      tags: ["prompt"],
      content: content,
      content_hash: hash,
      enabled: true
    })
    |> Repo.insert!()

    Registry.refresh()

    resp = mcp_request("prompts/get", %{"name" => "full-entry-prompt"})

    assert resp["error"]["code"] == -32_602
    assert resp["error"]["message"] =~ "Prompt not found"

    listed = mcp_request("prompts/list")
    refute Enum.any?(listed["result"]["prompts"], &(&1["name"] == "full-entry-prompt"))
  end
end
