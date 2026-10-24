defmodule Backplane.Admin.MemorySearchLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures

  alias Backplane.Memory.Memories.Memory

  test "searches stored memories across sources and retains source context in detail links", %{
    conn: conn
  } do
    first = memory!("Needle from the first source")
    second = memory!("Needle from another source", %{host_id: "search-other-host"})
    memory!("Unrelated content")

    memory!("Needle deleted")
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), lifecycle_state: "tombstoned")
    |> Backplane.Repo.update!()

    {:ok, view, _html} = live(conn, "/memory/search?q=needle")
    assert has_element?(view, "h1", "Search memories")
    assert has_element?(view, "#memory-search-count", "2 matching memories")
    assert has_element?(view, "#memory-search-results", first.content)
    assert has_element?(view, "#memory-search-results", second.content)
    refute has_element?(view, "#memory-search-results", "Unrelated content")
    refute has_element?(view, "#memory-search-results", "Needle deleted")
    refute has_element?(view, "#memory-access")

    render_patch(view, "/memory/search?q=needle&host=search-other-host")
    assert has_element?(view, "#memory-search-count", "1 matching memories")
    refute has_element?(view, "#memory-search-results", first.content)

    [href] =
      view
      |> element("#memory-search-results a")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("a", "href")

    assert URI.parse(href).path == "/memory/memories/#{second.id}"

    assert URI.decode_query(URI.parse(href).query) == %{
             "host" => "search-other-host",
             "q" => "needle",
             "offset" => "0"
           }
  end

  test "paginates matching results and starts a newly submitted search on the first page", %{
    conn: conn
  } do
    for index <- 1..26, do: memory!("Pagination needle #{index}")

    {:ok, view, _html} = live(conn, "/memory/search?q=needle&host=search-host")
    assert has_element?(view, "#memory-search-count", "26 matching memories")
    assert view |> element("#memory-search-results") |> render() |> result_count() == 25
    refute has_element?(view, "#memory-search-previous")

    view |> element("#memory-search-next") |> render_click()
    next_path = assert_patch(view)

    assert URI.decode_query(URI.parse(next_path).query) == %{
             "host" => "search-host",
             "q" => "needle",
             "offset" => "25"
           }

    assert view |> element("#memory-search-results") |> render() |> result_count() == 1
    assert has_element?(view, "#memory-search-previous")
    refute has_element?(view, "#memory-search-next")

    view
    |> form("#memory-search-form", search: %{q: "  no matching memories  "})
    |> render_submit()

    search_path = assert_patch(view)

    assert URI.decode_query(URI.parse(search_path).query) == %{
             "host" => "search-host",
             "q" => "no matching memories",
             "offset" => "0"
           }

    assert has_element?(view, "#memory-search-empty")
    assert has_element?(view, "#memory-search-count", "0 matching memories")
    refute has_element?(view, "#memory-search-results")
  end

  test "a failed search clears previous results and displays a readable error", %{conn: conn} do
    memory!("Previously visible needle")
    {:ok, view, _html} = live(conn, "/memory/search?q=needle")
    assert has_element?(view, "#memory-search-results", "Previously visible needle")

    fail_memory_reads!()
    render_patch(view, "/memory/search?q=retry")

    assert has_element?(
             view,
             ~s(#memory-search-error[title="Search unavailable"]),
             "The memory collection could not be searched. Try again."
           )

    refute has_element?(view, "#memory-search-results")
    refute has_element?(view, "#memory-search-count")
    refute has_element?(view, "#memory-search-empty")
  end

  defp memory!(content, attrs \\ %{}) do
    attrs = canonical_event_attrs(Map.put_new(attrs, :host_id, "search-host"))

    %Memory{}
    |> Memory.changeset(
      Map.merge(attrs, %{content: content, memory_type: "semantic", agent_id: "search-agent"})
    )
    |> Backplane.Repo.insert!()
  end

  defp result_count(html) do
    html |> Floki.parse_fragment!() |> Floki.find("#memory-search-results > li") |> length()
  end
end
