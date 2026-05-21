defmodule BackplaneWeb.SkillLiveTest do
  use Backplane.LiveCase

  alias Backplane.Settings
  alias Backplane.SkillArchiveCase

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = Settings.set("skills.blob.local_root", tmp_dir)

    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    on_exit(fn ->
      if Process.whereis(Settings), do: Settings.set("skills.blob.local_root", nil)
    end)

    :ok
  end

  test "/admin/skills renders inside the admin shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/skills")

    assert html =~ "Skills"
    assert html =~ ~s(href="/admin/skills")
    assert html =~ ~s(href="/admin/dashboard/overview")
    assert html =~ "Upload"
  end

  test "/admin/skill remains a compatibility alias", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/skill")

    assert html =~ "Skills"
    assert html =~ ~s(href="/admin/skills")
  end

  test "list shows uploaded skill name, slug, tags, hash, and size", %{conn: conn} do
    archive = ingest_archive("admin-elixir", "Admin Elixir", ["elixir", "otp"])

    {:ok, _view, html} = live(conn, "/admin/skills")

    assert html =~ "Admin Elixir"
    assert html =~ "admin-elixir"
    assert html =~ "elixir"
    assert html =~ "otp"
    assert html =~ hash(archive)
    assert html =~ "#{byte_size(archive)} B"
  end

  test "search filters the list", %{conn: conn} do
    ingest_archive("admin-elixir", "Admin Elixir", ["elixir"])
    ingest_archive("admin-react", "Admin React", ["react"])

    {:ok, view, _html} = live(conn, "/admin/skills")

    html =
      view
      |> form("#skill-search-form", %{"q" => "React"})
      |> render_submit()

    assert html =~ "Admin React"
    refute html =~ "Admin Elixir"
  end

  test "upload accepts .tar.gz and refreshes the list", %{conn: conn} do
    archive = archive("uploaded-admin", "Uploaded Admin", ["upload"])
    {:ok, view, _html} = live(conn, "/admin/skills")

    upload =
      file_input(view, "#skill-upload-form", :archive, [
        %{name: "uploaded-admin.tar.gz", content: archive, type: "application/x-tar+gzip"}
      ])

    assert render_upload(upload, "uploaded-admin.tar.gz") =~ "100%"
    html = render_submit(element(view, "#skill-upload-form"))

    assert html =~ "Uploaded Admin"
    assert html =~ "uploaded-admin"
  end

  test "invalid upload displays validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/skills")

    upload =
      file_input(view, "#skill-upload-form", :archive, [
        %{name: "bad.tar.gz", content: "not a tar", type: "application/x-tar+gzip"}
      ])

    render_upload(upload, "bad.tar.gz")
    html = render_submit(element(view, "#skill-upload-form"))

    assert html =~ "Invalid archive"
  end

  test "delete removes a skill and updates the list", %{conn: conn} do
    ingest_archive("delete-admin", "Delete Admin", ["delete"])
    {:ok, view, html} = live(conn, "/admin/skills")
    assert html =~ "Delete Admin"

    html =
      view
      |> element(~s(el-dm-button[phx-click="delete"][phx-value-slug="delete-admin"]))
      |> render_click()

    refute html =~ "Delete Admin"
    assert html =~ "Skill deleted"
  end

  defp ingest_archive(slug, name, tags) do
    archive = archive(slug, name, tags)
    {:ok, _skill} = Backplane.Skills.ingest_archive(archive, filename: "#{slug}.tar.gz")
    archive
  end

  defp archive(slug, name, tags) do
    skill_md = """
    ---
    name: #{name}
    description: #{name} description
    tags: #{inspect(tags)}
    ---

    # #{name}
    """

    SkillArchiveCase.tar_gz([
      {"#{slug}/SKILL.md", skill_md},
      {"#{slug}/meta.json", SkillArchiveCase.meta_json(%{"slug" => slug})}
    ])
  end

  defp hash(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
end
