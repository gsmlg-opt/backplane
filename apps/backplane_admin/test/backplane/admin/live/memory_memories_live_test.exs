defmodule Backplane.Admin.MemoryMemoriesLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Memories.Memory

  @space "30000000-0000-0000-0000-000000000005"
  @query %{
    "memory_space_id" => @space,
    "host" => "inventory-host",
    "client" => "inventory-client",
    "scope" => "inventory-scope",
    "namespace" => "private"
  }

  setup do
    %Backplane.MemorySpaces.MemorySpace{}
    |> Backplane.MemorySpaces.MemorySpace.changeset(%{
      id: @space,
      kind: "private",
      status: "active"
    })
    |> Backplane.Repo.insert!()

    :ok
  end

  test "unknown and invalid memory details render a readable state", %{conn: conn} do
    for id <- [Ecto.UUID.generate(), "invalid-id"] do
      {:ok, view, _html} = live(recycle(conn), path("/memory/memories/#{id}"))
      assert has_element?(view, "#memory-detail-unavailable")
      refute has_element?(view, "#memory-detail")
    end
  end

  test "explicit memory without a session keeps detail and audit available without source links",
       %{conn: conn} do
    memory = memory!("Explicit fact without a session", nil)
    assert is_nil(memory.session_id)

    {:ok, view, _html} = live(conn, path("/memory/memories/#{memory.id}"))

    assert has_element?(view, "#memory-detail", memory.content)
    assert has_element?(view, ~s(#memory-detail a[href^="/memory/audit?"]), "Audit")
    refute has_element?(view, ~s(#memory-detail a[href^="/memory/sessions/"]))
    refute has_element?(view, ~s(#memory-detail a[href^="/memory/replay?"]))
    assert has_element?(view, "#memory-evidence", "No durable evidence")
    assert has_element?(view, "#memory-detail-source", "Repository unresolved")
  end

  test "detail retains each stored repository and path association and escapes historical values",
       %{
         conn: conn
       } do
    sources = [
      %{
        "repository_id" => "example.org/Team/Repository",
        "checkout_root" => "/work/checkouts/first",
        "cwd" => "/work/checkouts/first/apps"
      },
      %{
        "repository_id" => "example.org/Team/Repository",
        "checkout_root" => "/work/checkouts/second",
        "cwd" => "/work/checkouts/second/lib"
      },
      %{"cwd" => "/offline/<script>source</script>"}
    ]

    project = "/historical/<b>project</b>"

    memory =
      memory!("Multiple stored source associations", nil)
      |> Memory.changeset(%{metadata: %{"repository_sources" => sources, "project" => project}})
      |> Backplane.Repo.update!()

    {:ok, inventory, _html} = live(conn, "/memory/memories")
    assert has_element?(inventory, "#memory-memories-table", "example.org/Team/Repository")
    refute has_element?(inventory, "#memory-memories-table", "/work/checkouts/first")

    {:ok, detail, _html} = live(recycle(conn), "/memory/memories/#{memory.id}")
    assert has_element?(detail, "#memory-detail-source", @query["host"])
    assert has_element?(detail, "#memory-detail-source", "Legacy project: #{project}")
    refute has_element?(detail, "#memory-detail-source script")
    refute has_element?(detail, "#memory-detail-source b")

    associations =
      detail
      |> element("#memory-detail-source")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find(".memory-repository-source")
      |> Enum.map(fn source -> Enum.map(Floki.find(source, "dd"), &Floki.text/1) end)

    assert associations == [
             [
               "example.org/Team/Repository",
               "/work/checkouts/first",
               "/work/checkouts/first/apps"
             ],
             [
               "example.org/Team/Repository",
               "/work/checkouts/second",
               "/work/checkouts/second/lib"
             ],
             ["Unresolved", "/offline/<script>source</script>"]
           ]
  end

  test "memory with a session retains partition-scoped session and replay links", %{conn: conn} do
    memory = memory!("Session-backed fact", "session-a")
    {:ok, view, _html} = live(conn, path("/memory/memories/#{memory.id}"))

    assert has_element?(
             view,
             ~s(#memory-detail a[href="#{path("/memory/sessions/session-a")}"]),
             "Session"
           )

    assert has_element?(
             view,
             ~s(#memory-detail a[href="#{path("/memory/replay", %{"session" => "session-a"})}"]),
             "Replay"
           )
  end

  test "session-filtered inventory excludes other sessions and preserves the filter in detail links",
       %{conn: conn} do
    selected = memory!("Expected session fact", "session-a")
    memory!("Other session fact", "session-b")

    {:ok, view, _html} = live(conn, path("/memory/memories", %{"session" => "session-a"}))

    assert has_element?(view, "#memory-memories-table", selected.content)
    refute render(view) =~ "Other session fact"

    assert has_element?(
             view,
             ~s(a[href*="/memory/memories/#{selected.id}?"][href*="session=session-a"])
           )
  end

  test "source filter form preserves active search and sorting when applying or clearing sources",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/memories?q=shared&sort=oldest&host=offline")

    assert has_element?(
             view,
             ~s(#memory-source-filters input[type="hidden"][name="q"][value="shared"])
           )

    assert has_element?(
             view,
             ~s(#memory-source-filters input[type="hidden"][name="sort"][value="oldest"])
           )

    html = view |> element("#memory-source-filters") |> render()
    [clear] = html |> Floki.parse_fragment!() |> Floki.find("a") |> Floki.attribute("href")
    assert URI.decode_query(URI.parse(clear).query) == %{"q" => "shared", "sort" => "oldest"}
  end

  test "global search, count, sorting, optional sources, and no-param detail use stored records",
       %{conn: conn} do
    a = memory!("Global shared source A", nil)
    foreign_space = Ecto.UUID.generate()

    Backplane.Repo.insert!(%Backplane.MemorySpaces.MemorySpace{
      id: foreign_space,
      kind: "private",
      status: "active"
    })

    b =
      a
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.merge(%{
        memory_space_id: foreign_space,
        host_id: "removed-host",
        client_id: "historical-client",
        content: "Global shared source B",
        metadata: %{
          "repository_sources" => [%{"repository_id" => "github.com/example/repository"}]
        }
      })

    b = Backplane.Repo.insert!(Memory.changeset(%Memory{}, b))
    {:ok, view, _} = live(conn, "/memory/memories?q=Global%20shared&sort=oldest")
    assert has_element?(view, "#memory-memories-table", a.content)
    assert has_element?(view, "#memory-memories-table", b.content)
    assert has_element?(view, "#memories-count", "2 matching memories")
    refute has_element?(view, "#memory-access")

    {:ok, filtered, _} =
      live(
        recycle(conn),
        "/memory/memories?host=removed-host&repository=github.com%2Fexample%2Frepository"
      )

    assert has_element?(filtered, "#memories-count", "1 matching memories")
    assert has_element?(filtered, "#memory-memories-table", b.content)
    refute render(filtered) =~ a.content
    {:ok, detail, _} = live(recycle(conn), "/memory/memories/#{b.id}")
    assert has_element?(detail, "#memory-detail", b.content)
    assert has_element?(detail, "#memory-detail a[href*='target=#{b.id}']", "Audit")
  end

  test "an already-open global inventory needs no registration and observes later data", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/memory/memories")
    assert has_element?(view, "#memory-memories")
    assert has_element?(view, "#memories-empty")
    refute html =~ "Select an exact partition"
    memory!("Later unregistered source", nil)
    send(view.pid, :refresh_memory_operator)
    assert has_element?(view, "#memory-memories-table", "Later unregistered source")
  end

  test "global inventory refresh preserves filtered second page and selected detail", %{
    conn: conn
  } do
    for n <- 1..26, do: memory!("Filtered fact #{n}", "selected-session")
    selected = memory!("Filtered fact selected", "selected-session")
    memory!("Filtered fact from another session", "other-session")

    filters = %{
      "q" => "Filtered fact",
      "type" => "semantic",
      "session" => "selected-session",
      "offset" => "25"
    }

    {:ok, view, _html} = live(conn, path("/memory/memories/#{selected.id}", filters))
    assert has_element?(view, "#memory-detail", selected.content)
    assert has_element?(view, "#memories-previous")
    refute has_element?(view, "#memories-next")

    send(view.pid, :refresh_memory_operator)

    assert has_element?(view, "#memory-detail", selected.content)
    assert has_element?(view, "#memories-count", "27 matching memories")
    assert has_element?(view, "#memories-previous")
    refute has_element?(view, "#memories-next")
    refute render(view) =~ "Filtered fact from another session"

    for {key, value} <- Map.take(filters, ~w(q type session)) do
      assert has_element?(view, ~s(input[name="filters[#{key}]"][value="#{value}"]))
    end

    assert has_element?(
             view,
             ~s(#memory-detail a[href="#{path("/memory/sessions/selected-session")}"]),
             "Session"
           )

    assert view |> element("#admin-sidebar") |> render() =~ @query["host"]
  end

  test "an already-open empty inventory observes later committed data without navigation", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, path("/memory/memories"))
    assert has_element?(view, "#memories-empty")

    memory!("Newly visible inventory fact", "session-new")

    assert eventually(fn ->
             has_element?(view, "#memory-memories-table", "Newly visible inventory fact")
           end)
  end

  test "a deleted selected record becomes unavailable while the URL filter remains selected", %{
    conn: conn
  } do
    memory = memory!("Selected fact", "session-a")
    url = path("/memory/memories/#{memory.id}", %{"session" => "session-a", "offset" => "0"})
    {:ok, view, _html} = live(conn, url)
    assert has_element?(view, "#memory-detail", "Selected fact")

    assert :ok = Backplane.Memory.Memories.forget(memory.id, Map.from_struct(memory))

    assert eventually(fn -> has_element?(view, "#memory-detail-unavailable") end)
    refute has_element?(view, "#memory-detail")
    assert has_element?(view, ~s(input[name="filters[session]"][value="session-a"]))
  end

  @tag :provenance_navigation
  @tag :provenance_navigation
  test "event evidence keeps the complete selected partition", %{conn: conn} do
    memory = memory!("Event backed fact", "source-event-session")

    event =
      Backplane.Admin.MemoryFixtures.event_fixture(
        Map.merge(
          Map.take(Map.from_struct(memory), [
            :memory_space_id,
            :host_id,
            :client_id,
            :scope,
            :namespace,
            :session_id
          ]),
          %{content: "Event source"}
        )
      )

    Backplane.Repo.insert!(%Backplane.Memory.Memories.Evidence{
      memory_id: memory.id,
      source_event_id: event.id,
      host_id: memory.host_id,
      session_id: memory.session_id,
      evidence_kind: "derives",
      support_score: 1.0
    })

    {:ok, view, _} = live(conn, path("/memory/memories/#{memory.id}"))

    assert has_element?(
             view,
             ~s(#memory-evidence a[href="#{path("/memory/events/#{event.id}")}"]),
             "Event"
           )
  end

  defp memory!(content, session) do
    %Memory{}
    |> Memory.changeset(%{
      memory_space_id: @space,
      host_id: @query["host"],
      client_id: @query["client"],
      scope: @query["scope"],
      namespace: @query["namespace"],
      content: content,
      memory_type: "semantic",
      agent_id: "inventory-agent",
      session_id: session,
      metadata: %{}
    })
    |> Backplane.Repo.insert!()
  end

  defp path(base, extra \\ %{}), do: base <> "?" <> URI.encode_query(Map.merge(@query, extra))

  defp eventually(check, attempts \\ 35)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(100)
      eventually(check, attempts - 1)
    end
  end
end
