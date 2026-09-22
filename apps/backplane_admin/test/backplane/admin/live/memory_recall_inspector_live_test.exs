defmodule Backplane.Admin.MemoryRecallInspectorLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures
  require Ecto.Query

  alias Backplane.Memory.Recall.{Candidate, QueryPlan, Store, TraceCandidate}
  alias Backplane.Memory.Memories.Memory
  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.Entitlement
  alias Backplane.Skills.Host

  setup do
    partition = partition_fixture("recall-ui")
    %{partition: partition, query: partition_query(partition)}
  end

  test "requires a complete URL partition before listing traces", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/recall")
    assert has_element?(view, "#recall-partition-empty", "Select an exact memory partition")
    assert has_element?(view, "input[name='memory_space_id'][required]")

    {:ok, view, _html} = live(recycle(conn), "/memory/recall?host=incomplete&client=client")
    assert has_element?(view, "#recall-partition-empty")
  end

  test "lists only the exact partition and preserves it in detail links", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "safe inspector query")
    _foreign = trace_fixture(partition_fixture("foreign-client"), "foreign query")

    foreign_runs =
      for foreign <- [
            partition_fixture("foreign-host"),
            partition_fixture("foreign-scope", "personal"),
            partition_fixture("foreign-namespace", "team", "other-namespace")
          ] do
        trace_fixture(foreign, "foreign #{foreign.host_id} #{foreign.scope} #{foreign.namespace}")
      end

    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(query))

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
    conn: conn,
    partition: partition,
    query: query
  } do
    failed = trace_fixture(partition, "failed match", status: :failed, correlation_id: "corr-a")
    _complete = trace_fixture(partition, "complete other", correlation_id: "corr-b")

    filtered_query = Map.merge(query, %{"status" => "failed", "correlation_id" => "corr-a"})
    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(filtered_query))
    assert html =~ failed.id
    refute html =~ "complete other"

    render_submit(view, "filter", %{
      "filters" => %{"status" => "complete", "cursor" => "discard-me"}
    })

    patched = assert_patch(view)
    patched_query = URI.decode_query(URI.parse(patched).query)
    assert patched_query["status"] == "complete"
    assert patched_query["memory_space_id"] == partition.memory_space_id
    refute Map.has_key?(patched_query, "cursor")

    assert {:error, {:live_redirect, %{to: canonical, flash: flash}}} =
             live(
               recycle(conn),
               "/memory/recall?" <> URI.encode_query(Map.put(query, "status", "bogus"))
             )

    assert flash["error"] == "One invalid recall parameter was removed."
    refute URI.decode_query(URI.parse(canonical).query) |> Map.has_key?("status")
  end

  test "detail shows explainability without candidate content and legacy provenance is explicit",
       %{
         conn: conn,
         partition: partition,
         query: query
       } do
    run = trace_fixture(partition, "safe inspector query")
    path = "/memory/recall/#{run.id}?" <> URI.encode_query(query)
    {:ok, view, html} = live(conn, path)

    assert has_element?(view, "#recall-run-detail")
    assert html =~ "Reranker"
    assert html =~ "Rank movement"
    assert html =~ "event:"
    refute html =~ "candidate secret content"
  end

  test "legacy trace provenance sentinel is rendered explicitly", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "legacy")
    repo = Application.fetch_env!(:backplane_memory, :repo)

    repo.update_all(
      Ecto.Query.from(candidate in TraceCandidate,
        where: candidate.recall_run_id == ^run.id
      ),
      set: [source_refs: %{"refs" => []}]
    )

    {:ok, _view, html} =
      live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(query))

    assert html =~ "Provenance unavailable (legacy trace)"
  end

  test "malformed IDs and incomplete or wrong partitions share literal 404", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "safe")

    for path <- [
          "/memory/recall/not-a-uuid?" <> URI.encode_query(query),
          "/memory/recall/#{run.id}?host=#{partition.host_id}",
          "/memory/recall/#{run.id}?" <>
            URI.encode_query(Map.put(query, "scope", "personal"))
        ] do
      assert get(recycle(conn), path) |> response(404) == "not found"
    end
  end

  test "repository failures are unavailable on index and literal 503 on detail", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "safe")
    fail_memory_reads!()

    {:ok, view, _html} = live(conn, "/memory/recall?" <> URI.encode_query(query))
    assert has_element?(view, "#recall-query-error")
    assert render(view) =~ "Memory data is unavailable"
    refute has_element?(view, "#recall-no-runs")

    path = "/memory/recall/#{run.id}?" <> URI.encode_query(query)
    assert get(recycle(conn), path) |> response(503) == "memory unavailable"
  end

  test "failed partition navigation clears previously loaded index traces", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "must disappear")
    {:ok, view, html} = live(conn, "/memory/recall?" <> URI.encode_query(query))
    assert html =~ run.id

    fail_memory_reads!()
    foreign_query = Map.put(query, "namespace", "unavailable")
    render_patch(view, "/memory/recall?" <> URI.encode_query(foreign_query))

    refute render(view) =~ run.id
    assert has_element?(view, "#recall-query-error")
  end

  test "failed detail reload clears previously loaded candidate traces", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "must disappear")
    path = "/memory/recall/#{run.id}?" <> URI.encode_query(query)
    {:ok, view, html} = live(conn, path)
    assert html =~ "recall-candidate-"

    fail_memory_reads!()
    render_patch(view, path <> "&selection=selected")

    refute render(view) =~ "recall-candidate-"
    assert has_element?(view, "#recall-query-error")
  end

  test "detail exposes accessible native progress, table semantics, and filter controls", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "safe")
    {:ok, view, _html} = live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(query))

    assert has_element?(view, "progress[aria-label='Recall token budget used']")
    assert has_element?(view, "table#recall-candidates-table thead")
    assert has_element?(view, "table#recall-candidates-table tbody")
    assert has_element?(view, "#candidate-filters fieldset legend", "Candidate result filters")
    assert has_element?(view, "#candidate-filters label", "Selection")
    assert has_element?(view, "ul[aria-label='Typed provenance']")
  end

  test "candidate result pages are bounded and selection and kind filters are URL-backed", %{
    conn: conn,
    partition: partition,
    query: query
  } do
    run = trace_fixture(partition, "many candidates", candidate_count: 51)
    {:ok, view, html} = live(conn, "/memory/recall/#{run.id}?" <> URI.encode_query(query))

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
          memory_type = if(kind == :lesson, do: :procedural, else: :semantic)
          content = "candidate secret content #{System.unique_integer([:positive, :monotonic])}"

          memory =
            Backplane.Repo.insert!(
              Memory.changeset(
                %Memory{},
                Map.merge(partition, %{
                  content: content,
                  memory_type: Atom.to_string(memory_type),
                  agent_id: "recall-inspector"
                })
              )
            )

          {:ok, candidate} =
            Candidate.new(
              Map.merge(Map.delete(partition, :source_client_id), %{
                id: memory.id,
                kind: kind,
                memory_type: memory_type,
                content: content,
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

  defp partition_query(partition) do
    %{
      "memory_space_id" => partition.memory_space_id,
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }
  end

  defp partition_fixture(prefix, scope \\ "team", namespace \\ "private") do
    host =
      Backplane.Repo.insert!(
        Host.changeset(%Host{}, %{
          name: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}",
          memory_scope: scope
        })
      )

    assert {:ok, canonical} = MemorySpaces.provision_private_host(host.id, host.memory_scope)

    if namespace != "private" do
      Backplane.Repo.insert!(
        Entitlement.changeset(%Entitlement{}, %{
          memory_space_id: canonical.memory_space_id,
          host_id: host.id,
          scope: scope,
          namespace: namespace,
          default_capture: false,
          status: "active"
        })
      )
    end

    source_client_id = "host:#{host.id}"

    Map.merge(canonical, %{
      host_id: host.id,
      client_id: source_client_id,
      source_client_id: source_client_id,
      namespace: namespace
    })
  end
end
