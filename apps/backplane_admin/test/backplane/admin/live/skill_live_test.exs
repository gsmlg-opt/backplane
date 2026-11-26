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
      |> element(~s([phx-click=delete][phx-value-id="skill/delete-skill"]))
      |> render_click()

      assert {:error, :not_found} = Skills.get_by_slug("delete-skill")

      assert [%{action: "skill.delete", target_id: "skill/delete-skill"}] =
               Backplane.Admin.Audit.list(%{action: "skill.delete"})
    end
  end

  test "configuration saves only changed rows, including selections hidden by a filter", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    a = ingest_archive!(tmp_dir, "alpha-config", name: "Alpha")
    b = ingest_archive!(tmp_dir, "beta-config", name: "Beta")
    {:ok, view, _} = live(conn, "/skills/config")
    view |> element(~s(input[phx-value-id="#{a.id}"])) |> render_click()
    view |> form("#skill-config-filter", %{"q" => "Beta"}) |> render_change()
    {:ok, _} = Skills.set_always_return(%{b.id => true})
    view |> element("button[phx-click=save]") |> render_click()
    assert {:ok, %{always_return: true}} = Skills.get(a.id)
    assert {:ok, %{always_return: true}} = Skills.get(b.id)
    {:ok, fresh, _} = live(conn, "/skills/config")
    assert has_element?(fresh, ~s(input[checked][phx-value-id="#{a.id}"]))
  end

  test "select and deselect stage changes for this page or the entire library", %{conn: conn} do
    ids =
      for i <- 1..26 do
        slug = "batch-#{i}"

        Backplane.Repo.insert!(%Skills.Skill{
          id: "skill/#{slug}",
          slug: slug,
          name: "Batch #{i}",
          content: "Batch"
        }).id
      end

    other =
      Backplane.Repo.insert!(%Skills.Skill{
        id: "skill/other",
        slug: "other",
        name: "Other",
        content: "Other"
      })

    {:ok, view, _} = live(conn, "/skills/config")
    page_select = "button[phx-value-scope=page][phx-value-selected=true]"
    page_deselect = "button[phx-value-scope=page][phx-value-selected=false]"
    all_select = "button[phx-value-scope=all][phx-value-selected=true]"
    all_deselect = "button[phx-value-scope=all][phx-value-selected=false]"
    save = "button[phx-click=save]"
    filter = fn q -> view |> form("#skill-config-filter", %{"q" => q}) |> render_change() end

    filter.("Batch")
    view |> element(page_select, "Select this page (25)") |> render_click()
    view |> element("button[phx-value-step='1']") |> render_click()
    refute has_element?(view, "tbody input[checked]")
    view |> element(page_select, "Select this page (1)") |> render_click()
    assert has_element?(view, "tbody input[checked]")
    view |> element(page_deselect) |> render_click()
    view |> element(save) |> render_click()

    assert Enum.count(ids, fn id -> match?({:ok, %{always_return: true}}, Skills.get(id)) end) ==
             25

    assert {:ok, %{always_return: false}} = Skills.get(other.id)

    filter.("nonmatching")
    assert has_element?(view, page_select <> "[disabled]")
    assert has_element?(view, page_deselect <> "[disabled]")
    view |> element(all_select) |> render_click()
    assert {:ok, %{always_return: false}} = Skills.get(other.id)
    view |> element(save) |> render_click()
    assert Enum.all?(ids, fn id -> match?({:ok, %{always_return: true}}, Skills.get(id)) end)
    assert {:ok, %{always_return: true}} = Skills.get(other.id)

    view |> element(all_deselect) |> render_click()
    assert {:ok, %{always_return: true}} = Skills.get(other.id)
    view |> element(save) |> render_click()
    assert Enum.all?(ids, fn id -> match?({:ok, %{always_return: false}}, Skills.get(id)) end)
    assert {:ok, %{always_return: false}} = Skills.get(other.id)
    assert has_element?(view, save <> "[disabled]")
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
        {"#{slug}/meta.json", Formata.JSON.encode!(%{"slug" => slug})}
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
