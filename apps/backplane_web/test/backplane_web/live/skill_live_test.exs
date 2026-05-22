defmodule BackplaneWeb.SkillLiveTest do
  use Backplane.LiveCase

  import Backplane.SkillArchiveCase

  alias Backplane.Skills
  alias Backplane.Skills.Hosts

  @moduletag :tmp_dir

  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    end)

    :ok
  end

  test "/admin/skills renders inside the admin shell and lists archive metadata", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    skill =
      ingest_archive!(tmp_dir, "alpha-skill",
        name: "Alpha Skill",
        tags: ["archive", "alpha"]
      )

    {:ok, _view, html} = live(conn, "/admin/skills")

    assert html =~ "Skills Hub"
    assert html =~ ~s(href="/admin/skills")
    assert html =~ ~s(href="/admin/dashboard/overview")
    assert html =~ "Alpha Skill"
    assert html =~ "alpha-skill"
    assert html =~ "archive"
    assert html =~ "alpha"
    assert html =~ skill.content_hash
    assert html =~ "#{skill.size_bytes} B"
  end

  test "/admin/skill still resolves for v1 compatibility", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/skill")

    assert html =~ "Skills Hub"
    assert html =~ ~s(href="/admin/skills")
    assert html =~ ~s(aria-current="page")
  end

  test "/admin/skills renders host sync section", %{conn: conn} do
    assert {:ok, _host, _token} =
             Hosts.create_host(%{
               "name" => "t430",
               "agent_version" => "0.1.0",
               "targets" => [
                 %{
                   "name" => "agents",
                   "runtime" => "agent-skills",
                   "path" => "/tmp/skills",
                   "enabled" => true
                 }
               ]
             })

    {:ok, view, html} = live(conn, "/admin/skills")

    assert html =~ "Host Agents"
    assert html =~ "t430"
    assert html =~ "0.1.0"
    assert html =~ "unknown"
    assert has_element?(view, "#host-agents-table", "1")
  end

  test "search filters the skills list", %{conn: conn, tmp_dir: tmp_dir} do
    ingest_archive!(tmp_dir, "alpha-skill", name: "Alpha Skill", tags: ["archive", "alpha"])
    ingest_archive!(tmp_dir, "beta-skill", name: "Beta Skill", tags: ["archive", "beta"])

    {:ok, view, html} = live(conn, "/admin/skills")

    assert html =~ "Alpha Skill"
    assert html =~ "Beta Skill"

    html =
      view
      |> element("#skill-search-form")
      |> render_submit(%{"q" => "alpha"})

    assert html =~ "Alpha Skill"
    refute html =~ "Beta Skill"
  end

  test "uploading a tar.gz archive ingests and lists the skill", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    archive = create_skill_archive!(tmp_dir, "upload-skill", name: "Upload Skill")

    {:ok, view, _html} = live(conn, "/admin/skills")

    upload =
      file_input(view, "#skill-upload-form", :archive, [
        %{
          name: "upload-skill.tar.gz",
          content: File.read!(archive),
          type: "application/gzip"
        }
      ])

    assert render_upload(upload, "upload-skill.tar.gz") =~ "100%"

    html =
      view
      |> element("#skill-upload-form")
      |> render_submit()

    assert {:ok, skill} = Skills.get_by_slug("upload-skill")
    assert html =~ "Upload Skill"
    assert html =~ "upload-skill"
    assert html =~ skill.content_hash
  end

  test "invalid upload displays a validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/skills")

    upload =
      file_input(view, "#skill-upload-form", :archive, [
        %{
          name: "invalid-skill.tar.gz",
          content: "not a tar archive",
          type: "application/gzip"
        }
      ])

    assert render_upload(upload, "invalid-skill.tar.gz") =~ "100%"

    html =
      view
      |> element("#skill-upload-form")
      |> render_submit()

    assert html =~ "Upload failed"
    assert {:error, :not_found} = Skills.get_by_slug("invalid-skill")
  end

  test "delete removes a skill and updates the list", %{conn: conn, tmp_dir: tmp_dir} do
    ingest_archive!(tmp_dir, "delete-skill", name: "Delete Skill")

    {:ok, view, html} = live(conn, "/admin/skills")

    assert html =~ "Delete Skill"

    view
    |> element("#delete-skill-delete")
    |> render_click()

    refute has_element?(view, "#delete-skill-delete")
    assert {:error, :not_found} = Skills.get_by_slug("delete-skill")
  end

  defp ingest_archive!(tmp_dir, slug, attrs) do
    archive = create_skill_archive!(tmp_dir, slug, attrs)
    assert {:ok, skill} = Skills.ingest_archive(archive, [])
    skill
  end

  defp create_skill_archive!(tmp_dir, slug, attrs) do
    create_archive!(
      tmp_dir,
      [
        {"#{slug}/SKILL.md", skill_content(attrs)},
        {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})}
      ],
      name: "#{slug}.tar.gz"
    )
  end

  defp skill_content(attrs) do
    name = Keyword.get(attrs, :name, "Example Skill")
    description = Keyword.get(attrs, :description, "Example skill")
    version = Keyword.get(attrs, :version, "1.0.0")
    tags = attrs |> Keyword.get(:tags, ["archive", "test"]) |> Enum.join(", ")

    """
    ---
    name: #{name}
    description: #{description}
    tags: [#{tags}]
    version: "#{version}"
    ---

    # #{name}

    Use this skill in LiveView tests.
    """
  end
end
