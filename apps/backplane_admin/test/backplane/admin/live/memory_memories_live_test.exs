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

  test "sources identify each stored host and agent in the global inventory and detail", %{
    conn: conn
  } do
    host = source_host!("Rikka workstation")
    other_host = source_host!("Other workstation")
    memory = memory!("Rikka source fact", nil, %{host_id: host.id, agent_id: "Rikka"})
    other = memory!("Other source fact", nil, %{host_id: other_host.id, agent_id: "Other agent"})

    {:ok, view, _} = live(conn, "/memory/memories")

    for {record, source_host, agent} <- [
          {memory, host, "Rikka"},
          {other, other_host, "Other agent"}
        ] do
      row = "#memory-memories-table tr:has(a[href*='#{record.id}'])"
      assert has_element?(view, row, "Host: #{source_host.name}")
      assert has_element?(view, row, "Agent: #{agent}")
    end

    refute has_element?(
             view,
             "#memory-memories-table tr:has(a[href*='#{memory.id}'])",
             other_host.name
           )

    refute has_element?(
             view,
             "#memory-memories-table tr:has(a[href*='#{memory.id}'])",
             "Other agent"
           )

    {:ok, detail, _} = live(recycle(conn), "/memory/memories/#{memory.id}")
    assert has_element?(detail, "#memory-detail-source", "Host: #{host.name}")
    assert has_element?(detail, "#memory-detail-source", "Host ID: #{host.id}")
    assert has_element?(detail, "#memory-detail-source", "Agent: Rikka")

    host
    |> Backplane.Skills.Host.changeset(%{name: "Renamed workstation"})
    |> Backplane.Repo.update!()

    send(detail.pid, :refresh_memory_operator)
    assert has_element?(detail, "#memory-detail-source", "Host: Renamed workstation")
    assert has_element?(detail, "#memory-detail-source", "Host ID: #{host.id}")
    assert has_element?(detail, "#memory-detail-source", "Agent: Rikka")
  end

  test "unregistered source hosts retain their IDs and source identity values are escaped", %{
    conn: conn
  } do
    host = source_host!("<script>registered host</script>")
    memory = memory!("Escaped source fact", nil, %{host_id: host.id, agent_id: "<b>Rikka</b>"})
    removed_host = Ecto.UUID.generate()
    historical = memory!("Historical source fact", nil, %{host_id: removed_host})
    historical_host = "<script>historical host</script>"
    memory!("Escaped historical source fact", nil, %{host_id: historical_host})

    {:ok, view, _} = live(conn, "/memory/memories")
    assert has_element?(view, "#memory-memories-table", "Host: #{host.name}")
    assert has_element?(view, "#memory-memories-table", "Agent: <b>Rikka</b>")
    assert has_element?(view, "#memory-memories-table", "Host: #{removed_host}")
    assert has_element?(view, "#memory-memories-table", "Host: #{historical_host}")
    refute has_element?(view, "#memory-memories-table script")
    refute has_element?(view, "#memory-memories-table b")

    {:ok, detail, _} = live(recycle(conn), "/memory/memories/#{memory.id}")
    assert has_element?(detail, "#memory-detail-source", "Host: #{host.name}")
    assert has_element?(detail, "#memory-detail-source", "Agent: <b>Rikka</b>")
    refute has_element?(detail, "#memory-detail-source script")
    refute has_element?(detail, "#memory-detail-source b")

    Backplane.Repo.delete!(host)
    send(detail.pid, :refresh_memory_operator)
    assert has_element?(detail, "#memory-detail-source", "Host: #{host.id}")
    refute has_element?(detail, "#memory-detail-source", host.name)

    {:ok, historical_detail, _} = live(recycle(conn), "/memory/memories/#{historical.id}")
    assert has_element?(historical_detail, "#memory-detail-source", "Host: #{removed_host}")
  end

  test "missing agents remain unknown instead of using source metadata" do
    for agent_id <- [nil, "", " "] do
      html =
        render_component(&Backplane.Admin.MemoryOperatorComponents.source_identity/1, %{
          record: %{
            host_id: agent_id,
            agent_id: agent_id,
            metadata: %{"agent_id" => "Guessed agent"}
          }
        })

      assert Floki.text(Floki.parse_fragment!(html)) =~ "Agent: Unknown agent"
      assert Floki.text(Floki.parse_fragment!(html)) =~ "Host: Unknown host"
      refute html =~ "Guessed agent"
    end
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

  test "stored session IDs identify conversations and link to same-session memories in their partition",
       %{conn: conn} do
    session = "local-7153008f162595e0d82c47208db5f052434aaaa5f26d2f9cba4d74f2e5248ab6"
    selected = memory!("Selected conversation turn", session)
    companion = memory!("Another turn in the same conversation", session)
    other = memory!("A different conversation", "local-another-conversation")
    foreign_space = Ecto.UUID.generate()

    Backplane.Repo.insert!(%Backplane.MemorySpaces.MemorySpace{
      id: foreign_space,
      kind: "private",
      status: "active"
    })

    foreign =
      memory!("Same session string from a foreign source", session, %{
        memory_space_id: foreign_space,
        host_id: "foreign-session-host",
        client_id: "foreign-session-client"
      })

    {:ok, inventory, _} = live(conn, "/memory/memories")
    same_session_path = path("/memory/memories", %{"session" => session, "offset" => 0})
    row = "#memory-memories-table tr:has(a[href*='/memory/memories/#{selected.id}?'])"

    assert has_element?(inventory, "#{row} a[href=\"#{same_session_path}\"]", session)

    assert has_element?(
             inventory,
             "#memory-memories-table tr:has(a[href*='/memory/memories/#{other.id}?'])",
             other.session_id
           )

    {:ok, detail, _} =
      live(recycle(conn), "/memory/memories/#{selected.id}?q=Selected&offset=25")

    assert has_element?(detail, "#memory-detail-session", "Session ID")
    assert has_element?(detail, "#memory-detail-session", session)

    detail
    |> element(~s(#memory-detail a[href="#{same_session_path}"]), "Same-session memories")
    |> render_click()

    assert_patch(detail, same_session_path)
    assert has_element?(detail, "#memories-count", "2 matching memories")
    assert has_element?(detail, "#memory-memories-table", selected.content)
    assert has_element?(detail, "#memory-memories-table", companion.content)
    refute has_element?(detail, "#memory-memories-table", other.content)
    refute has_element?(detail, "#memory-memories-table", foreign.content)
    assert has_element?(detail, ~s(#memories-session[value="#{session}"]))
    refute has_element?(detail, "#memories-previous")
    refute has_element?(detail, "#memory-detail")
  end

  test "session IDs are escaped while sessionless records show no invented conversation links", %{
    conn: conn
  } do
    session = ~s(session-<script>historical</script>?&")
    memory = memory!("Historical session source", session)
    {:ok, view, _} = live(conn, "/memory/memories")

    assert has_element?(view, "#memory-memories-table", session)
    refute has_element?(view, "#memory-memories-table script")

    {:ok, detail, _} = live(recycle(conn), "/memory/memories/#{memory.id}")
    assert has_element?(detail, "#memory-detail-session", session)
    refute has_element?(detail, "#memory-detail-session script")

    href =
      detail
      |> element("#memory-detail", "Same-session memories")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("a")
      |> Enum.find(&(Floki.text(&1) == "Same-session memories"))
      |> then(&Floki.attribute(&1, "href"))
      |> hd()

    assert URI.decode_query(URI.parse(href).query)["session"] == session

    for session_id <- [nil, "", " "] do
      sessionless =
        memory!("Sessionless #{inspect(session_id)}", nil)
        |> Ecto.Changeset.change(session_id: session_id)
        |> Backplane.Repo.update!()

      {:ok, no_session, _} = live(recycle(conn), "/memory/memories/#{sessionless.id}")
      assert has_element?(no_session, "#memory-detail-session", "No session recorded")
      refute has_element?(no_session, "#memory-detail a", "Same-session memories")
      refute has_element?(no_session, ~s(#memory-detail a[href^="/memory/sessions/"]))
      refute has_element?(no_session, ~s(#memory-detail a[href^="/memory/replay?"]))

      row = "#memory-memories-table tr:has(a[href*='/memory/memories/#{sessionless.id}?'])"
      assert has_element?(no_session, row, "No session recorded")
      refute has_element?(no_session, "#{row} a[href*='session=']")
    end
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
    assert has_element?(detail, "#memory-access-target", foreign_space)
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

  test "details lead the inventory and failed navigation clears content and pagination", %{
    conn: conn
  } do
    memory = memory!("Readable selected memory", "detail-first-session")
    detail_path = path("/memory/memories/#{memory.id}")
    {:ok, view, html} = live(conn, detail_path)
    {detail_at, _} = :binary.match(html, ~s(id="memory-detail"))
    {table_at, _} = :binary.match(html, ~s(id="memory-memories-table"))
    assert detail_at < table_at
    assert has_element?(view, "#memory-detail a", "Back to memories")
    refute has_element?(view, "#memory-access[open]")
    original_repo = Application.fetch_env!(:backplane_memory, :repo)
    Backplane.Admin.MemoryFixtures.fail_memory_reads!()

    render_patch(view, detail_path <> "&offset=25")
    assert has_element?(view, "#memories-error")
    refute has_element?(view, "#memory-detail")
    refute has_element?(view, "#memory-memories-table")
    refute has_element?(view, "#memories-count")
    refute has_element?(view, "#memories-previous")
    refute has_element?(view, "#memories-next")
    refute has_element?(view, "#memory-source-summary")

    Application.put_env(:backplane_memory, :repo, original_repo)
    render_patch(view, detail_path)
    refute has_element?(view, "#memories-error")
    assert has_element?(view, "#memory-detail", memory.content)
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
  test "summary evidence opens its immutable source revision and rejects an unlinked source", %{
    conn: conn
  } do
    memory = memory!("Fact with historical summary", "source-session")
    subject = Backplane.Memory.Projections.Source.subject_id!(memory.host_id, memory.session_id)

    Backplane.Repo.insert!(%Backplane.Memory.Projections.ProjectedSession{
      subject_id: subject,
      memory_space_id: @space,
      host_id: memory.host_id,
      client_id: memory.client_id,
      scope: memory.scope,
      namespace: memory.namespace,
      session_id: memory.session_id,
      input_revision: "R2",
      status: "completed",
      last_event_at: DateTime.utc_now(),
      processing_version: "session-v1"
    })

    summaries =
      for revision <- ["R1", "R2"] do
        Backplane.Repo.insert!(%Backplane.Memory.Summaries.Summary{
          subject_id: subject,
          memory_space_id: @space,
          host_id: memory.host_id,
          scope: memory.scope,
          namespace: memory.namespace,
          session_id: memory.session_id,
          content: "Summary body " <> revision,
          input_revision: revision,
          output_revision: "output-" <> revision,
          processing_version: "summary-v1-" <> revision,
          superseded_at: if(revision == "R1", do: DateTime.utc_now())
        })
      end

    for summary <- summaries do
      Backplane.Repo.insert!(%Backplane.Memory.Memories.Evidence{
        memory_id: memory.id,
        source_summary_id: summary.id,
        host_id: memory.host_id,
        session_id: memory.session_id,
        evidence_kind: "derives",
        support_score: 1.0
      })
    end

    for {summary, status} <- Enum.zip(summaries, ["Historical", "Current"]) do
      url = path("/memory/memories/#{memory.id}", %{"source_summary" => summary.id})
      {:ok, view, _} = live(recycle(conn), url)
      assert has_element?(view, ~s(#memory-evidence a[href="#{url}"]), "Session summary")
      assert has_element?(view, "#memory-source-summary", summary.id)
      assert has_element?(view, "#memory-source-summary", summary.input_revision)
      assert has_element?(view, "#memory-source-summary", summary.content)
      assert has_element?(view, "#memory-source-summary", status)

      assert has_element?(
               view,
               ~s(#memory-detail a[href="#{path("/memory/sessions/source-session")}"]),
               "Session"
             )
    end

    for source_id <- [Ecto.UUID.generate(), "invalid"] do
      {:ok, view, _} =
        live(
          recycle(conn),
          path("/memory/memories/#{memory.id}", %{"source_summary" => source_id})
        )

      assert has_element?(view, "#memory-source-summary-unavailable")
      refute has_element?(view, "#memory-source-summary")
      assert has_element?(view, "#memory-detail", memory.content)
    end
  end

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

  describe "exact partition host access" do
    test "grants the chosen recipient the exact target independently of source provenance", %{
      conn: conn
    } do
      recipient = registered_host!("Shared recipient", "recipient-private-scope")
      memory!("Existing private content", "source-session")
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))

      assert has_element?(view, "#memory-access-target", @space)
      assert has_element?(view, "#memory-access-target", @query["scope"])
      assert has_element?(view, "#memory-access-sharing-warning", "including private content")
      select_recipient(view, recipient.id)

      submit_access(view, %{
        "read" => "true",
        "deliver" => "true",
        "reason" => "Share existing facts",
        "offline_read_lease_seconds" => "30"
      })

      assert has_element?(view, "#memory-access-success")
      assert {:ok, [access]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert access.host_id == recipient.id
      assert access.partition == access_partition()
      assert Enum.sort(access.capabilities) == [:deliver, :read]
      assert access.offline_read_lease_seconds == 30
      assert access.default_capture == false
      assert access.latest_audit_reason == "Share existing facts"
      assert has_element?(view, "#memory-access-table", recipient.name)
      assert has_element?(view, "#memory-access-table", "Share existing facts")
      assert has_element?(view, "#memory-memories-table", "Existing private content")
      refute has_element?(view, "#memory-access-table", @query["host"])
    end

    test "remember and forget are separately granted without read or delivery", %{conn: conn} do
      recipient = registered_host!("Independent writer", "writer-private")
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)
      submit_access(view, %{"remember" => "true", "reason" => "Allow append only"})
      assert {:ok, [remember]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert remember.capabilities == [:remember]
      assert has_element?(view, "#memory-access-remember[checked]")
      refute has_element?(view, "#memory-access-read[checked]")
      refute has_element?(view, "#memory-access-forget[checked]")

      submit_access(view, %{"forget" => "true", "reason" => "Allow independent deletion"})
      assert {:ok, [forget]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert forget.capabilities == [:forget]
      assert forget.access_id == remember.access_id
      assert forget.authority_version == remember.authority_version + 1
      refute has_element?(view, "#memory-access-deliver[checked]")
    end

    test "rejects deliver without read, missing reason, invalid lease, and unknown recipients", %{
      conn: conn
    } do
      recipient = registered_host!("Validation recipient", "validation-private")
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)

      submit_access(view, %{"deliver" => "true", "reason" => "Invalid delivery"})
      assert has_element?(view, "#memory-access-error", "Deliver requires read")
      submit_access(view, %{"read" => "true", "reason" => "   "})
      assert has_element?(view, "#memory-access-error", "reason is required")

      submit_access(view, %{
        "read" => "true",
        "reason" => "Invalid lease",
        "offline_read_lease_seconds" => "301"
      })

      assert has_element?(view, "#memory-access-error", "0 to 300")

      submit_access(view, %{
        "read" => "true",
        "reason" => "Lease needs delivery",
        "offline_read_lease_seconds" => "1"
      })

      assert has_element?(view, "#memory-access-error", "requires read and deliver")
      assert {:ok, []} = Backplane.MemorySpaces.list_partition_access(access_partition())

      render_hook(view, "memory_access_change", %{
        "access" => %{"host_id" => Ecto.UUID.generate()}
      })

      render_hook(view, "memory_access_save", %{
        "access" => %{"read" => "true", "reason" => "Unknown host"}
      })

      assert has_element?(view, "#memory-access-error", "known registered recipient")
      assert {:ok, []} = Backplane.MemorySpaces.list_partition_access(access_partition())
      refute has_element?(view, "#memory-access-success")
    end

    test "unavailable access state disables mutations while retaining the exact target", %{
      conn: conn
    } do
      {:ok, view, _} =
        live_with_sandbox(conn, path("/memory/memories", %{"memory_space_id" => "invalid-space"}))

      assert has_element?(view, "#memory-access-target", "invalid-space")
      assert has_element?(view, "#memory-access-load-error", "could not be loaded")
      assert has_element?(view, "#memory-access-save[disabled]")
      refute has_element?(view, "#memory-access-success")
    end

    test "domain rejection renders a safe failure without reporting success", %{conn: conn} do
      recipient = registered_host!("Rejected recipient", "rejected-private")
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)

      Backplane.Repo.get!(Backplane.MemorySpaces.MemorySpace, @space)
      |> Backplane.MemorySpaces.MemorySpace.changeset(%{status: "disabled"})
      |> Backplane.Repo.update!()

      submit_access(view, %{"read" => "true", "reason" => "Space no longer available"})
      assert has_element?(view, "#memory-access-error", "could not be updated")
      refute has_element?(view, "#memory-access-success")
      assert {:ok, []} = Backplane.MemorySpaces.list_partition_access(access_partition())
    end

    test "CAS conflict refreshes the list while preserving the reviewed draft version", %{
      conn: conn
    } do
      recipient = registered_host!("Concurrent recipient", "concurrent-private")
      access = grant_access!(recipient.id, [:read])
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)

      assert {:ok, newer} =
               Backplane.MemorySpaces.change_host_access(
                 operator(),
                 access.access_id,
                 access.authority_version,
                 %{capabilities: [:forget]},
                 "Another operator changed access"
               )

      submit_access(view, %{"remember" => "true", "reason" => "My stale intent"})

      assert has_element?(view, "#memory-access-error", "changed since this draft")
      assert has_element?(view, "#memory-access-table", "Another operator changed access")
      assert has_element?(view, "#memory-access-remember[checked]")
      assert has_element?(view, ~s(#memory-access-version[value="#{access.authority_version}"]))
      assert has_element?(view, ~s(#memory-access-reason[value="My stale intent"]))
      assert {:ok, [current]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert current.authority_version == newer.authority_version
      assert current.capabilities == [:forget]

      view |> element("#memory-access-edit-#{access.access_id}") |> render_click()
      assert has_element?(view, ~s(#memory-access-version[value="#{newer.authority_version}"]))
      assert has_element?(view, "#memory-access-forget[checked]")
    end

    test "stale revoke and regrant cannot overwrite newer authority", %{conn: conn} do
      recipient = registered_host!("Stale lifecycle recipient", "stale-lifecycle-private")
      access = grant_access!(recipient.id, [:read])
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)

      assert {:ok, changed} =
               Backplane.MemorySpaces.change_host_access(
                 operator(),
                 access.access_id,
                 access.authority_version,
                 %{capabilities: [:remember]},
                 "Newer authority before revoke"
               )

      submit_access(view, %{"reason" => "Stale revoke", "action" => "revoke"})
      assert has_element?(view, "#memory-access-error", "changed since this draft")
      assert {:ok, [current]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert current.status == :active
      assert current.authority_version == changed.authority_version

      assert {:ok, revoked} =
               Backplane.MemorySpaces.revoke_host_access(
                 operator(),
                 changed.access_id,
                 changed.authority_version,
                 "Current revoke"
               )

      send(view.pid, :refresh_memory_operator)
      assert eventually(fn -> has_element?(view, "#memory-access-table", "Current revoke") end)
      view |> element("#memory-access-edit-#{access.access_id}") |> render_click()
      assert has_element?(view, "#memory-access-save", "Regrant")

      assert {:ok, regranted} =
               Backplane.MemorySpaces.grant_host_access(
                 operator(),
                 recipient.id,
                 access_partition(),
                 [:read],
                 reason: "Newer regrant",
                 expected_version: revoked.authority_version
               )

      submit_access(view, %{"forget" => "true", "reason" => "Stale regrant"})
      assert has_element?(view, "#memory-access-error", "changed since this draft")
      assert has_element?(view, "#memory-access-table", "Newer regrant")
      assert {:ok, [current]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert current.capabilities == [:read]
      assert current.authority_version == regranted.authority_version
    end

    test "revoke and regrant retain the access identity and require current versions", %{
      conn: conn
    } do
      recipient = registered_host!("Revoked recipient", "revoke-private")
      access = grant_access!(recipient.id, [:read, :deliver])
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))
      select_recipient(view, recipient.id)
      submit_access(view, %{"reason" => "   ", "action" => "revoke"})
      assert has_element?(view, "#memory-access-error", "reason is required")

      submit_access(view, %{
        "deliver" => "true",
        "offline_read_lease_seconds" => "301",
        "reason" => "Stop sharing",
        "action" => "revoke"
      })

      assert {:ok, [revoked]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert revoked.status == :revoked
      assert revoked.access_id == access.access_id
      assert revoked.capabilities == access.capabilities
      assert revoked.offline_read_lease_seconds == access.offline_read_lease_seconds
      assert revoked.authority_version == access.authority_version + 1
      refute has_element?(view, "#memory-access-revoke")
      assert has_element?(view, "#memory-access-save", "Regrant")

      submit_access(view, %{"forget" => "true", "reason" => "Restore selected authority"})
      assert {:ok, [regranted]} = Backplane.MemorySpaces.list_partition_access(access_partition())
      assert regranted.status == :active
      assert regranted.access_id == access.access_id
      assert regranted.authority_version == revoked.authority_version + 1
      assert regranted.capabilities == [:forget]
      assert Backplane.Skills.Hosts.get_host(recipient.id)
    end

    test "refresh preserves unsaved access fields, reason, version, and filtered detail URL", %{
      conn: conn
    } do
      recipient = registered_host!("Draft recipient", "draft-private")
      access = grant_access!(recipient.id, [:read])
      memory = memory!("Selected access fact", "draft-session")

      filters = %{
        "q" => "Selected",
        "type" => "semantic",
        "session" => "draft-session",
        "offset" => "0"
      }

      url = path("/memory/memories/#{memory.id}", filters)
      {:ok, view, _} = live_with_sandbox(conn, url)
      assert_patch(view, url)
      select_recipient(view, recipient.id)

      view
      |> form("#memory-access-form",
        access:
          access_params(%{
            "host_id" => recipient.id,
            "read" => "true",
            "deliver" => "true",
            "remember" => "true",
            "offline_read_lease_seconds" => "42",
            "reason" => "Draft for review"
          })
      )
      |> render_change()

      assert {:ok, newer} =
               Backplane.MemorySpaces.change_host_access(
                 operator(),
                 access.access_id,
                 access.authority_version,
                 %{capabilities: [:forget]},
                 "Refreshed authority"
               )

      send(view.pid, :refresh_memory_operator)

      assert eventually(fn ->
               has_element?(view, "#memory-access-table", "Refreshed authority")
             end)

      assert has_element?(
               view,
               ~s(#memory-access-recipient option[value="#{recipient.id}"][selected])
             )

      assert has_element?(view, "#memory-access-read[checked]")
      assert has_element?(view, "#memory-access-deliver[checked]")
      assert has_element?(view, "#memory-access-remember[checked]")
      assert has_element?(view, ~s(#memory-access-lease[value="42"]))
      assert has_element?(view, ~s(#memory-access-reason[value="Draft for review"]))
      assert has_element?(view, ~s(#memory-access-version[value="#{access.authority_version}"]))
      assert has_element?(view, "#memory-detail", memory.content)

      for {key, value} <- Map.take(filters, ~w(q type session)),
          do: assert(has_element?(view, ~s(input[name="filters[#{key}]"][value="#{value}"])))

      refute_patched(view)
      assert newer.authority_version > access.authority_version

      # Provenance selection changes do not change the authority target or draft.
      render_patch(
        view,
        path("/memory/memories/#{memory.id}", Map.put(filters, "host", "other-source-host"))
      )

      assert has_element?(view, ~s(#memory-access-reason[value="Draft for review"]))
      render_patch(view, path("/memory/memories", %{"scope" => "another-exact-scope"}))
      assert has_element?(view, ~s(#memory-access-reason[value=""]))
      assert has_element?(view, ~s(#memory-access-version[value="0"]))
    end

    test "recipient selection includes registered hosts beyond the navigation picker limit", %{
      conn: conn
    } do
      for n <- 1..51 do
        %Backplane.Skills.Host{}
        |> Backplane.Skills.Host.changeset(%{
          name: "Full recipient #{String.pad_leading(to_string(n), 2, "0")}",
          memory_scope: "full-recipient-#{n}"
        })
        |> Backplane.Repo.insert!()
      end

      recipient = registered_host!("ZZ final recipient", "last-recipient")
      {:ok, view, _} = live_with_sandbox(conn, path("/memory/memories"))

      assert has_element?(
               view,
               ~s(#memory-access-recipient option[value="#{recipient.id}"]),
               recipient.name
             )

      select_recipient(view, recipient.id)
      submit_access(view, %{"read" => "true", "reason" => "Complete recipient list"})
      assert has_element?(view, "#memory-access-success")
    end

    test "default capture warning is truthful and revocation preserves canonical data", %{
      conn: conn
    } do
      host = registered_host!("Default capture owner", "default-capture-scope")

      assert {:ok, partition} =
               Backplane.MemorySpaces.resolve_host_partition(
                 host.id,
                 host.memory_scope,
                 "private"
               )

      query = %{
        "memory_space_id" => partition.memory_space_id,
        "host" => host.id,
        "client" => "host:#{host.id}",
        "scope" => partition.scope,
        "namespace" => partition.namespace
      }

      %Memory{}
      |> Memory.changeset(
        Map.merge(partition, %{
          host_id: host.id,
          client_id: "host:#{host.id}",
          content: "Retained canonical fact",
          agent_id: "default-owner-agent",
          memory_type: "semantic",
          metadata: %{}
        })
      )
      |> Backplane.Repo.insert!()

      {:ok, view, _} = live_with_sandbox(conn, "/memory/memories?" <> URI.encode_query(query))
      select_recipient(view, host.id)
      assert has_element?(view, "#memory-access-default-warning", "stops capture")

      submit_access(view, %{
        "read" => "true",
        "deliver" => "true",
        "remember" => "true",
        "forget" => "true",
        "reason" => "Stop default capture deliberately",
        "action" => "revoke"
      })

      assert has_element?(view, "#memory-access-success")
      assert has_element?(view, "#memory-memories-table", "Retained canonical fact")
      assert {:ok, [access]} = Backplane.MemorySpaces.list_partition_access(partition)
      assert access.status == :revoked
      refute access.default_capture
    end
  end

  defp select_recipient(view, host_id) do
    view |> form("#memory-access-form", access: %{host_id: host_id}) |> render_change()
  end

  defp submit_access(view, overrides) do
    submitter =
      if overrides["action"] == "revoke", do: "#memory-access-revoke", else: "#memory-access-save"

    view
    |> form("#memory-access-form", access: access_params(Map.delete(overrides, "action")))
    |> put_submitter(submitter)
    |> render_submit()
  end

  defp access_params(overrides) do
    Map.merge(
      %{
        "read" => "false",
        "deliver" => "false",
        "remember" => "false",
        "forget" => "false",
        "offline_read_lease_seconds" => "0",
        "reason" => ""
      },
      overrides
    )
  end

  defp access_partition,
    do: %{memory_space_id: @space, scope: @query["scope"], namespace: @query["namespace"]}

  defp operator, do: %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

  defp grant_access!(host_id, capabilities) do
    assert {:ok, access} =
             Backplane.MemorySpaces.grant_host_access(
               operator(),
               host_id,
               access_partition(),
               capabilities,
               reason: "Initial test authority",
               expected_version: 0
             )

    access
  end

  defp registered_host!(name, scope) do
    assert {:ok, host} =
             Backplane.Skills.Hosts.create_agent(%{"name" => name, "memory_scope" => scope})

    on_exit(fn -> Backplane.Skills.AgentManage.stop_agent(host.id) end)
    host
  end

  defp source_host!(name) do
    %Backplane.Skills.Host{}
    |> Backplane.Skills.Host.changeset(%{
      name: name,
      memory_scope: "source-#{Ecto.UUID.generate()}"
    })
    |> Backplane.Repo.insert!()
  end

  defp memory!(content, session, overrides \\ %{}) do
    %Memory{}
    |> Memory.changeset(
      Map.merge(
        %{
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
        },
        overrides
      )
    )
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
