defmodule Backplane.Admin.SkillConfigLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.{Repo, Settings}
  alias Backplane.Settings.Setting
  alias Backplane.Skills.{SearchCategories, Skill}

  setup do
    key = SearchCategories.key()
    previous = :ets.lookup(:backplane_settings, key)
    :ok = Settings.set(key, [])

    on_exit(fn ->
      :ets.delete(:backplane_settings, key)
      :ets.insert(:backplane_settings, previous)
    end)

    :ok
  end

  test "labels the multiline category setting and restores it when reopened", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/skills/config")
    assert has_element?(view, "label[for=skill-search-categories]", "Search categories")

    assert has_element?(
             view,
             "textarea#skill-search-categories[aria-describedby=skill-search-categories-helper]"
           )

    view
    |> form("#skill-search-categories-form", categories: "  Android debugging\niOS debugging\n")
    |> render_submit()

    assert SearchCategories.list() == ["Android debugging", "iOS debugging"]

    assert Repo.get!(Setting, SearchCategories.key()).value == %{
             "v" => ["Android debugging", "iOS debugging"]
           }

    assert render(view) =~ "Search categories saved."

    {:ok, fresh, _html} = live(conn, "/skills/config")

    assert fresh
           |> render()
           |> Floki.parse_document!()
           |> Floki.find("#skill-search-categories")
           |> Floki.text() == "Android debugging\niOS debugging"

    assert [
             %{
               action: "skill.search_categories_updated",
               target_type: "system_setting",
               target_id: "skills.search_categories"
             }
           ] =
             Backplane.Admin.Audit.list(%{action: "skill.search_categories_updated"})
  end

  test "validation preserves input and staged Always return selections", %{conn: conn} do
    skill =
      Repo.insert!(%Skill{
        id: "search-category-view",
        slug: "search-category-view",
        name: "Category View",
        content: "Body"
      })

    {:ok, view, _html} = live(conn, "/skills/config")
    view |> element(~s(input[phx-value-id="#{skill.id}"])) |> render_click()
    too_long = String.duplicate("x", 513)

    view |> form("#skill-search-categories-form", categories: too_long) |> render_submit()

    assert has_element?(
             view,
             "#skill-search-categories[aria-invalid=true][aria-describedby=skill-search-categories-errors]",
             too_long
           )

    assert render(view) =~ "Each category must fit within 512 UTF-8 bytes."
    assert has_element?(view, ~s(input[checked][phx-value-id="#{skill.id}"]))
    assert SearchCategories.list() == []
    assert Repo.get!(Skill, skill.id).always_return == false

    view
    |> form("#skill-search-categories-form", categories: "Android debugging")
    |> render_submit()

    assert SearchCategories.list() == ["Android debugging"]
    assert has_element?(view, ~s(input[checked][phx-value-id="#{skill.id}"]))
    assert Repo.get!(Skill, skill.id).enabled
    assert Repo.get!(Skill, skill.id).always_return == false

    view |> form("#skill-search-categories-form", categories: "") |> render_submit()
    assert SearchCategories.list() == []
  end
end
