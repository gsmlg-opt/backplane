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

  test "prompts/get returns content from the full skill entry" do
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

    assert %{
             "result" => %{
               "description" => "Prompt backed by a full skill fetch",
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => %{"type" => "text", "text" => ^content}
                 }
               ]
             }
           } = resp
  end
end
