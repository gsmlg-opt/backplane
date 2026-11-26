defmodule Backplane.Skills.GitHubPublicationTest do
  use BackplaneSkills.DataCase, async: false
  alias Backplane.Skills
  alias Backplane.Skills.{Publication, SkillSources}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    setting = "skills.blob.local_root"
    before = :ets.lookup(:backplane_settings, setting)
    :ets.insert(:backplane_settings, {setting, tmp})
    old_adapter = Application.get_env(:backplane_skills, :github_http_adapter)
    Application.put_env(:backplane_skills, :github_http_adapter, {HTTP.Test, __MODULE__})

    on_exit(fn ->
      :ets.delete(:backplane_settings, setting)
      :ets.insert(:backplane_settings, before)

      if old_adapter,
        do: Application.put_env(:backplane_skills, :github_http_adapter, old_adapter),
        else: Application.delete_env(:backplane_skills, :github_http_adapter)
    end)

    :ok
  end

  test "sync publishes complete commit snapshots and preserves operator choices" do
    {:ok, source} =
      SkillSources.create(%{name: "github-fixture", url: "https://github.com/example/skills"})

    stub_snapshot("one", "100644")
    assert {:ok, %{synced: 1, errors: []}} = SkillSources.sync_from_source(source)
    {:ok, first} = Skills.get("github/root")
    assert first.publication_status == "ready"
    assert {:ok, rev} = Publication.resolve(first.id, first.current_revision)
    assert Enum.any?(rev.manifest["files"], &(&1["path"] == "references/list.md"))
    assert {:ok, %{synced: 1}} = SkillSources.sync_from_source(source)
    assert {:ok, %{current_revision: same}} = Skills.get(first.id)
    assert same == first.current_revision
    {:ok, _} = Skills.set_always_return(%{first.id => true})
    {:ok, _} = Skills.update(first, %{enabled: false})
    stub_snapshot("two", "100644")
    assert {:ok, %{synced: 1}} = SkillSources.sync_from_source(source)
    assert {:ok, %{enabled: false, always_return: true} = second} = Skills.get(first.id)
    refute second.current_revision == first.current_revision
    stub_snapshot("ref", "120000")
    assert {:ok, %{synced: 0, errors: [_]}} = SkillSources.sync_from_source(source)
    assert {:ok, %{current_revision: retained}} = Skills.get(first.id)
    assert retained == second.current_revision
  end

  defp stub_snapshot(reference, mode) do
    sha = :crypto.hash(:sha, reference) |> Base.encode16(case: :lower)
    doc = "---\nname: root\ndescription: Example work\n---\n\nquartzneedle"

    tree =
      for {path, bytes, file_mode} <- [
            {"SKILL.md", doc, "100644"},
            {"references/list.md", reference, mode}
          ] do
        %{
          "path" => "skills/root/" <> path,
          "type" => "blob",
          "mode" => file_mode,
          "size" => byte_size(bytes)
        }
      end

    HTTP.Test.stub(__MODULE__, fn request ->
      case URI.parse(to_string(request.url)).path do
        "/repos/example/skills/commits/main" ->
          HTTP.Test.json(%{"sha" => sha})

        "/repos/example/skills/git/trees/" <> ^sha ->
          HTTP.Test.json(%{"tree" => tree, "truncated" => false})

        path ->
          assert String.starts_with?(path, "/example/skills/#{sha}/skills/root/")

          HTTP.Test.response(
            200,
            if(String.ends_with?(path, "SKILL.md"), do: doc, else: reference)
          )
      end
    end)
  end
end
