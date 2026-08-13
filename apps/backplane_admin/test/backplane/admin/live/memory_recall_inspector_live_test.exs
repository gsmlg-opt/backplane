defmodule Backplane.Admin.MemoryRecallInspectorLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures
  require Ecto.Query

  alias Backplane.Memory.Recall.{Candidate, QueryPlan, Store, TraceCandidate}

  @partition %{host_id: "host-a", client_id: "client-a", scope: "team", namespace: "private"}
  @query %{
    "host" => "host-a",
    "client" => "client-a",
    "scope" => "team",
    "namespace" => "private"
  }

  test "requires a complete URL partition before listing traces", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/recall")
    assert has_element?(view, "#recall-partition-empty", "Select an exact memory partition")

    {:ok, view, _html} = live(recycle(conn), "/memory/recall?host=host-a&client=client-a")
    assert has_element?(view, "#recall-partition-empty")
  end

  test "lists only the exact partition and preserves it in detail links", %{conn: conn} do
    run = trace_fixture(@partition, "safe inspector query")
    _foreign = trace_fixture(%{@partition | client_id: "other-client"}, "foreign query")

    foreign_runs =
      for foreign <- [
            %{@partition | host_id: "other-host"},
            %{@partition | scope: "personal"},
            %{@partition | namespace: "other-namespace"}
          ] do
        trace_fixture(foreign, "foreign #{foreign.host_id} #{foreign.scope} #{foreign.namespace}")
      end

    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(@query))

    assert has_element?(view, "#recall-run-#{run.id}")
    refute html =~ "foreign query"

    assert has_element?(
             view,
             ~s|a[href^="/memory/recall/#{run.id}?"]|,
             "View details"
           )

    Enum.each(foreign_runs, &refute(html =~ &1.id))
  end

  test "list filters are URL-backed, invalid values canonicalize, and submit drops cursor", %{
    conn: conn
  } do
    failed = trace_fixture(@partition, "failed match", status: :failed, correlation_id: "corr-a")
    _complete = trace_fixture(@partition, "complete other", correlation_id: "corr-b")

    query = Map.merge(@query, %{"status" => "failed", "correlation_id" => "corr-a"})
    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(query))
    assert html =~ failed.id
    refute html =~ "complete other"

    render_submit(view, "filter", %{
      "filters" => %{"status" => "complete", "cursor" => "discard-me"}
    })

    patched = assert_patch(view)
    assert URI.decode_query(URI.parse(patched).query)["status"] == "complete"
    refute URI.decode_query(URI.parse(patched).query) |> Map.has_key?("cursor")

    assert {:error, {:live_redirect, %{to: canonical, flash: flash}}} =
             live(
               recycle(conn),
               "/memory/recall?" <> URI.encode_query(Map.put(@query, "status", "bogus"))
             )

    assert flash["error"] == "One invalid recall parameter was removed."
    refute URI.decode_query(URI.parse(canonical).query) |> Map.has_key?("status")
  end

  test "detail shows explainability without candidate content and legacy provenance is explicit",
       %{
         conn: conn
       } do
    run = trace_fixture(@partition, "safe inspector query")
    path = "/memory/recall/#{run.id}?" <> URI.encode_query(@query)
    {:ok, view, html} = live(conn, path)

    assert has_element?(view, "#recall-run-detail")
    assert html =~ "Reranker"
    assert html =~ "Rank movement"
    assert html =~ "event:"
    refute html =~ "candidate secret content"
  end

  test "legacy trace provenance sentinel is rendered explicitly", %{conn: conn} do
    run = trace_fixture(@partition, "legacy")
    repo = Application.fetch_env!(:backplane_memory, :repo)

    repo.update_all(
      Ecto.Query.from(candidate in TraceCandidate,
        where: candidate.recall_run_id == ^run.id
      ),
      set: [source_refs: %{"refs" => []}]
    )

    {:ok, _view, html} =
      live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(@query))

    assert html =~ "Provenance unavailable (legacy trace)"
  end

  test "malformed IDs and incomplete or wrong partitions share literal 404", %{conn: conn} do
    run = trace_fixture(@partition, "safe")

    for path <- [
          "/memory/recall/not-a-uuid?" <> URI.encode_query(@query),
          "/memory/recall/#{run.id}?host=host-a",
          "/memory/recall/#{run.id}?" <> URI.encode_query(%{@query | "scope" => "personal"})
        ] do
      assert get(recycle(conn), path) |> response(404) == "not found"
    end
  end

  test "repository failures are unavailable on index and literal 503 on detail", %{conn: conn} do
    run = trace_fixture(@partition, "safe")
    fail_memory_reads!()

    {:ok, view, _html} = live(conn, "/memory/recall?" <> URI.encode_query(@query))
    assert has_element?(view, "#recall-query-error")
    assert render(view) =~ "Memory data is unavailable"
    refute has_element?(view, "#recall-no-runs")

    path = "/memory/recall/#{run.id}?" <> URI.encode_query(@query)
    assert get(recycle(conn), path) |> response(503) == "memory unavailable"
  end

  test "failed partition navigation clears previously loaded index traces", %{conn: conn} do
    run = trace_fixture(@partition, "must disappear")
    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(@query))
    assert html =~ run.id

    fail_memory_reads!()
    foreign_query = Map.put(@query, "namespace", "unavailable")
    render_patch(view, "/memory/recall?" <> URI.encode_query(foreign_query))

    refute render(view) =~ run.id
    assert has_element?(view, "#recall-query-error")
  end

  test "failed detail reload clears previously loaded candidate traces", %{conn: conn} do
    run = trace_fixture(@partition, "must disappear")
    path = "/memory/recall/#{run.id}?" <> URI.encode_query(@query)
    {:ok, view, html} = live(conn, path)
    assert html =~ "recall-candidate-"

    fail_memory_reads!()
    render_patch(view, path <> "&selection=selected")

    refute render(view) =~ "recall-candidate-"
    assert has_element?(view, "#recall-query-error")
  end

  test "detail exposes accessible native progress, table semantics, and filter controls", %{
    conn: conn
  } do
    run = trace_fixture(@partition, "safe")
    {:ok, view, _html} = live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(@query))

    assert has_element?(view, "progress[aria-label='Recall token budget used']")
    assert has_element?(view, "table#recall-candidates-table thead")
    assert has_element?(view, "table#recall-candidates-table tbody")
    assert has_element?(view, "#candidate-filters fieldset legend", "Candidate result filters")
    assert has_element?(view, "#candidate-filters label", "Selection")
    assert has_element?(view, "ul[aria-label='Typed provenance']")
  end

  test "candidate result pages are bounded and selection and kind filters are URL-backed", %{
    conn: conn
  } do
    run = trace_fixture(@partition, "many candidates", candidate_count: 51)
    {:ok, view, html} = live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(@query))

    assert length(Regex.scan(~r/id="recall-candidate-/, html)) == 50
    assert has_element?(view, "#candidate-next-page")

    render_submit(view, "candidate_filter", %{
      "candidate_filters" => %{"selection" => "rejected", "kind" => "lesson"}
    })

    patched = assert_patch(view)
    params = patched |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["selection"] == "rejected"
    assert params["kind"] == "lesson"
    assert render(view) =~ "Excluded by diversity limits."
  end

  defp trace_fixture(partition, query, opts \\ []) do
    {:ok, plan} = QueryPlan.new(Map.put(partition, :query, query))

    {:ok, run} =
      Store.create(plan,
        request_id: Ecto.UUID.generate(),
        correlation_id:
          Keyword.get(opts, :correlation_id, "corr-#{System.unique_integer([:positive])}")
      )

    if Keyword.get(opts, :status) == :failed do
      {:ok, failed} = Store.fail(run.id, partition, failure_class: "provider")
      failed
    else
      count = Keyword.get(opts, :candidate_count, 1)

      traces =
        for index <- 1..count do
          source_id = Ecto.UUID.generate()
          selected = index < count or count == 1
          kind = if(selected, do: :memory, else: :lesson)

          {:ok, candidate} =
            Candidate.new(
              Map.merge(partition, %{
                id: Ecto.UUID.generate(),
                kind: kind,
                memory_type: :semantic,
                content: "candidate secret content",
                source_ids: [source_id],
                source_refs: [%{type: :event, id: source_id}]
              })
            )

          %{
            candidate: candidate,
            selected: selected,
            rejection_reason: if(selected, do: nil, else: "diversity"),
            ranks: %{fts: index},
            scores: %{fts: 0.8, final: 0.8},
            pre_reranker_rank: index,
            post_reranker_rank: index
          }
        end

      {:ok, run} =
        Store.finalize(
          run.id,
          partition,
          traces,
          latency_ms: 3,
          reranker_status: :disabled,
          reranker_provider: "none",
          reranker_error_class: "disabled",
          reranker_duration_ms: 0
        )

      run
    end
  end
end
