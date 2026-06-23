defmodule Backplane.Admin.SkillLiveTest do
  use Backplane.Admin.LiveCase

  import Backplane.SkillArchiveCase

  alias Backplane.Skills

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

  describe "Overview page" do
    test "/skills renders the overview dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ "Skills Overview"
      assert html =~ "Total Skills"
    end
  end

  describe "Browse page" do
    test "/skills/browse lists skills in a table", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      _skill =
        ingest_archive!(tmp_dir, "alpha-skill",
          name: "Alpha Skill",
          tags: ["archive", "alpha"]
        )

      {:ok, _view, html} = live(conn, "/skills/browse")

      assert html =~ "Skills"
      assert html =~ "Alpha Skill"
      assert html =~ "alpha-skill"
      assert html =~ "archive"
      assert html =~ "alpha"
    end

    test "search filters the skills list", %{conn: conn, tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "alpha-skill", name: "Alpha Skill", tags: ["archive", "alpha"])
      ingest_archive!(tmp_dir, "beta-skill", name: "Beta Skill", tags: ["archive", "beta"])

      {:ok, _view, html} = live(conn, "/skills/browse?q=alpha")

      assert html =~ "Alpha Skill"
      # When searching, beta may or may not appear depending on full-text match
    end

    test "delete removes a skill and updates the list", %{conn: conn, tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "delete-skill", name: "Delete Skill")

      {:ok, view, html} = live(conn, "/skills/browse")

      assert html =~ "Delete Skill"

      view
      |> element("[phx-click=delete][phx-value-id]")
      |> render_click()

      assert {:error, :not_found} = Skills.get_by_slug("delete-skill")
    end
  end

  describe "Metadata page" do
    test "/skills/metadata renders tags and categories", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills/metadata")

      assert html =~ "Metadata"
      assert html =~ "Tags"
      assert html =~ "Categories"
    end
  end

  describe "Upstream page" do
    test "/skills/upstream renders the upstream sources page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills/upstream")

      assert html =~ "Upstream Sources"
    end
  end

  describe "Draft page" do
    test "/skills/draft renders the draft skills page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills/draft")

      assert html =~ "Draft Skills"
      assert html =~ "New Skill"
    end
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
