defmodule Backplane.Admin.MemoryPipelineLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures
  import Backplane.Memory.IngestFixtures, only: [valid_event: 1, ingest_auth_context: 2]
  alias Backplane.Settings
  @pipeline "memory.pipeline.enabled"
  setup :setup_memory_gates

  test "offers one background processing switch without implementation selectors", %{conn: conn} do
    {:ok, view, html} = live(conn, "/memory/pipeline")
    assert has_element?(view, "#pipeline-gate[role=switch]")
    assert length(Floki.find(Floki.parse_fragment!(html), "[role=switch]")) == 1
    refute has_element?(view, "#events-gate")
    refute has_element?(view, "#dual-write-gate")
    refute html =~ "Recall V2"
    assert html =~ "Memory capture and recall remain available"
    assert length(Floki.find(Floki.parse_fragment!(html), "#later-stages .later-stage")) == 4
  end

  test "pauses processing even when derived stages remain configured", %{conn: conn} do
    previous = Settings.get("memory.window_summaries.enabled")
    on_exit(fn -> Settings.set("memory.window_summaries.enabled", previous) end)
    Settings.set(@pipeline, true)
    Settings.set("memory.window_summaries.enabled", true)
    {:ok, view, _} = live(conn, "/memory/pipeline")
    render_change(view, "set-gate", %{"gate" => %{"name" => "pipeline", "value" => "false"}})
    assert Settings.get(@pipeline) == false
    assert Settings.get("memory.window_summaries.enabled") == true
    refute has_element?(view, "#pipeline-gate[checked]")
    assert has_element?(view, "#stage-window_summaries", "Blocked")
  end

  test "rejects obsolete and malformed gate submissions", %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/pipeline")

    for {gate, value} <- [
          {"events", "true"},
          {"dual_write", "true"},
          {"recall_v2", "true"},
          {"pipeline", "1"}
        ] do
      render_change(view, "set-gate", %{"gate" => %{"name" => gate, "value" => value}})
      assert has_element?(view, "#pipeline-mutation-error")
      refute Settings.get(@pipeline)
    end

    assert [] = Backplane.Admin.Audit.list()
  end

  test "reloads the persisted processing state on change notifications", %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/pipeline")
    Settings.set(@pipeline, true)
    send(view.pid, {:setting_changed, @pipeline, true})
    assert has_element?(view, "#pipeline-gate[checked]")
  end

  test "adapter failure retains the last persisted processing state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/pipeline")
    fail_memory_settings!()
    render_change(view, "set-gate", %{"gate" => %{"name" => "pipeline", "value" => "true"}})
    assert has_element?(view, "#pipeline-mutation-error", "could not be saved")
    refute has_element?(view, "#pipeline-gate[checked]")
  end

  @partition %{
    "memory_space_id" => "30000000-0000-0000-0000-000000000011",
    "host" => "pipeline-host",
    "client" => "host:pipeline-host",
    "scope" => "private",
    "namespace" => "private"
  }

  test "renders actual stage enablement and blocked reasons", %{conn: conn} do
    previous = Settings.get("memory.window_summaries.enabled")
    on_exit(fn -> Settings.set("memory.window_summaries.enabled", previous) end)
    assert :ok = Settings.set("memory.window_summaries.enabled", true)
    {:ok, view, _} = live(conn, "/memory/pipeline")
    assert has_element?(view, "#stage-window_summaries", "Blocked")
    assert has_element?(view, "#stage-window_summaries", "Enable Pipeline")
    assert :ok = Settings.set(@pipeline, true)
    send(view.pid, {:setting_changed, @pipeline, true})
    assert has_element?(view, "#stage-window_summaries", "Enabled")
  end

  test "shows exact-partition states and valid session recovery links without provider payloads",
       %{conn: conn} do
    ensure_space!(@partition["memory_space_id"])

    event =
      valid_event(%{
        "host_id" => @partition["host"],
        "client_id" => "codex-cli",
        "scope" => @partition["scope"],
        "session_id" => "pipeline-session",
        "event_type" => "agent.session.started"
      })

    auth =
      ingest_auth_context(@partition["host"], %{
        partition: %{
          memory_space_id: @partition["memory_space_id"],
          scope: @partition["scope"],
          namespace: @partition["namespace"]
        }
      })

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Backplane.Memory.Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => @partition["host"],
               "events" => [event]
             })

    assert {:ok, _} =
             Backplane.Memory.Projections.Rebuild.session(@partition["host"], "pipeline-session")

    subject_id =
      Backplane.Memory.Projections.Source.subject_id!(@partition["host"], "pipeline-session")

    state =
      insert_state!(%{
        subject_id: subject_id,
        subject_type: "captured_session",
        source_client_id: "codex-cli",
        status: "failed",
        input_revision: "source-r2",
        output_revision: "output-r1",
        attempt_count: 2,
        last_error: "raw provider response token=super-secret"
      })

    for {key, value} <- [
          host_id: "other-host",
          client_id: "other-client",
          scope: "other-scope",
          namespace: "other-namespace"
        ] do
      memory = insert_memory!(%{key => value})
      insert_memory_state!(memory, %{input_revision: "hidden-#{key}"})
    end

    other_space = Ecto.UUID.generate()
    ensure_space!(other_space)
    other_memory = insert_memory!(%{memory_space_id: other_space})
    insert_memory_state!(other_memory, %{input_revision: "hidden-space"})
    {:ok, view, html} = live(conn, pipeline_path())
    assert has_element?(view, "#pipeline-state-#{state.id}")
    assert has_element?(view, "#pipeline-states", "source-r2")
    assert has_element?(view, "#pipeline-states", "output-r1")
    assert has_element?(view, "#pipeline-states", "2")
    assert has_element?(view, "#pipeline-states", "Processing failed")

    assert has_element?(
             view,
             "#pipeline-states a[href*='/memory/sessions/pipeline-session?']",
             "Inspect / retry"
           )

    refute html =~ "super-secret"
    refute html =~ "raw provider response"
    refute html =~ "hidden-"

    Backplane.Repo.update!(
      Ecto.Changeset.change(state, status: "complete", output_revision: "output-r2")
    )

    send(view.pid, :refresh_memory_operator)
    assert has_element?(view, "#pipeline-states", "complete")
    assert has_element?(view, "#pipeline-states", "output-r2")

    [source_path] =
      render(view)
      |> Floki.parse_fragment!()
      |> Floki.find("#pipeline-states a")
      |> Floki.attribute("href")
      |> Enum.uniq()

    {:ok, source_view, _} = live(conn, source_path)
    assert has_element?(source_view, "#session-consolidation", "Consolidate / retry")
  end

  test "window states link only to the exact owning session and partition", %{conn: conn} do
    ensure_space!(@partition["memory_space_id"])

    for {subject, host} <- [{"owner", @partition["host"]}, {"foreign-owner", "foreign-host"}] do
      %Backplane.Memory.Projections.ProjectedSession{
        subject_id: subject,
        session_id: "session-#{subject}",
        status: "completed",
        last_event_at: DateTime.utc_now(),
        processing_version: "session-v1",
        input_revision: "r1",
        memory_space_id: @partition["memory_space_id"],
        host_id: host,
        client_id: @partition["client"],
        scope: @partition["scope"],
        namespace: @partition["namespace"]
      }
      |> Backplane.Repo.insert!()
    end

    for subject <- [
          "owner:window:c3RyZWFt:0",
          "owner-other:window:c3RyZWFt:0",
          "foreign-owner:window:c3RyZWFt:0"
        ] do
      insert_state!(%{
        subject_id: subject,
        subject_type: "captured_session_window",
        projector: "window_summary"
      })
    end

    {:ok, view, _} = live(conn, pipeline_path())

    links =
      render(view)
      |> Floki.parse_fragment!()
      |> Floki.find("#pipeline-states a")
      |> Floki.attribute("href")

    assert [path] = links
    assert path =~ "/memory/sessions/session-owner?"
    refute path =~ "foreign"
    refute render(view) =~ "owner-other:window"
    refute render(view) =~ "foreign-owner:window"
  end

  test "bounds states and shows query failure instead of empty success", %{conn: conn} do
    ensure_space!(@partition["memory_space_id"])
    for _index <- 1..52, do: insert_memory_state!(insert_memory!(%{}), %{})
    # Unverifiable newer states must not consume the authorized result limit.
    for index <- 1..52, do: insert_state!(%{subject_id: "unknown-#{index}"})
    {:ok, view, _} = live(conn, pipeline_path())

    assert length(
             render(view)
             |> Floki.parse_fragment!()
             |> Floki.find("#pipeline-states tbody tr")
           ) == 50

    refute has_element?(view, "#pipeline-states a[href*='/memory/sessions/']")
    assert has_element?(view, "#pipeline-state-limit", "50")
    :ok = fail_memory_reads!()
    send(view.pid, :refresh_memory_operator)
    assert has_element?(view, "#pipeline-states-error", "could not be loaded")
    refute render(view) =~ "forced memory repository failure"
  end

  test "verifies canonical owners for every subject without trusting capture client IDs" do
    ensure_space!(@partition["memory_space_id"])
    other_space = Ecto.UUID.generate()
    ensure_space!(other_space)
    partition = owner_attrs()

    selected =
      for override <- [
            %{},
            %{memory_space_id: other_space},
            %{host_id: "foreign-host"},
            %{client_id: "host:pipeline-host:other"},
            %{scope: "private:other"},
            %{namespace: "private:other"}
          ] do
        owner = Map.merge(partition, override)
        project = "project:#{Ecto.UUID.generate()}"
        subject = "session:#{Ecto.UUID.generate()}"

        session =
          struct!(
            Backplane.Memory.Projections.ProjectedSession,
            Map.merge(owner, %{
              subject_id: subject,
              session_id: subject,
              project: project,
              source_client_id: "codex-cli",
              status: "completed",
              last_event_at: DateTime.utc_now(),
              processing_version: "session-v1",
              input_revision: "r1"
            })
          )
          |> Backplane.Repo.insert!()

        memory = insert_memory!(Map.merge(owner, %{metadata: %{"project" => project}}))

        struct!(
          Backplane.Memory.Profiles.Profile,
          Map.merge(owner, %{project: project, updated_at: DateTime.utc_now()})
        )
        |> Backplane.Repo.insert!()

        identity = owner_identity(owner) ++ [project]
        state_owner = Map.delete(owner, :client_id) |> Map.put(:source_client_id, "codex-cli")

        states =
          for {type, projector, subject_id, status} <- [
                {"captured_session", "summary", session.subject_id, "failed"},
                {"captured_session_window", "window_summary", subject <> ":window:c3RyZWFt:0",
                 "skipped_no_model"},
                {"memory", "embed", memory.id, "dead_letter"},
                {"memory_partition", "procedural", Enum.join(identity, ":"), "skipped_disabled"},
                {"memory_profile", "profile", profile_identity(identity), "complete"}
              ] do
            insert_state!(
              Map.merge(state_owner, %{
                subject_type: type,
                projector: projector,
                subject_id: subject_id,
                status: status
              })
            )
          end

        # A prefix match is insufficient for procedural ownership.
        insert_state!(
          Map.merge(state_owner, %{
            subject_type: "memory_partition",
            projector: "procedural",
            subject_id: Enum.join(identity, ":") <> ":foreign-project"
          })
        )

        if override == %{}, do: Enum.map(states, & &1.id), else: []
      end
      |> List.flatten()

    # Also cover procedural ownership proved by memory metadata alone, with
    # non-string projects normalized to the worker's empty project identity.
    insert_memory!(%{metadata: %{"project" => 123}})

    memory_only =
      insert_state!(%{
        subject_type: "memory_partition",
        projector: "procedural",
        source_client_id: "codex-cli",
        subject_id: Enum.join(owner_identity(partition) ++ [""], ":")
      })

    insert_state!(%{subject_type: "memory_profile", projector: "profile", subject_id: "unknown"})
    insert_state!(%{subject_type: "unknown", subject_id: "unknown"})

    assert {:ok, rows} = Backplane.Memory.Operations.StageStatus.list(partition)
    assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([memory_only.id | selected])
    assert Enum.count(rows, &is_binary(&1.session_id)) == 2
  end

  test "processing inventory opens directly without a source selection", %{conn: conn} do
    {:ok, view, _} = live(conn, "/memory/pipeline")
    refute has_element?(view, "#memory-source-filters")
    refute has_element?(view, "#pipeline-partition")
    refute has_element?(view, "#pipeline-states")
  end

  defp pipeline_path, do: "/memory/pipeline?" <> URI.encode_query(@partition)

  defp ensure_space!(id) do
    %Backplane.MemorySpaces.MemorySpace{}
    |> Backplane.MemorySpaces.MemorySpace.changeset(%{id: id, kind: "private", status: "active"})
    |> Backplane.Repo.insert!()
  end

  defp owner_attrs do
    %{
      memory_space_id: @partition["memory_space_id"],
      host_id: @partition["host"],
      client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"]
    }
  end

  defp owner_identity(owner) do
    [owner.memory_space_id, owner.host_id, owner.client_id, owner.scope, owner.namespace]
  end

  defp profile_identity(identity) do
    Base.url_encode64(:erlang.term_to_binary(identity, [:deterministic]), padding: false)
  end

  defp insert_memory!(attrs) do
    %Backplane.Memory.Memories.Memory{}
    |> Backplane.Memory.Memories.Memory.changeset(
      owner_attrs()
      |> Map.merge(%{
        content: "owned #{Ecto.UUID.generate()}",
        agent_id: "pipeline-test",
        source_client_id: "codex-cli"
      })
      |> Map.merge(attrs)
    )
    |> Backplane.Repo.insert!()
  end

  defp insert_memory_state!(memory, attrs) do
    memory
    |> Map.take([:memory_space_id, :host_id, :source_client_id, :scope, :namespace])
    |> Map.put(:subject_id, memory.id)
    |> Map.merge(attrs)
    |> insert_state!()
  end

  defp insert_state!(attrs) do
    defaults = %{
      memory_space_id: @partition["memory_space_id"],
      host_id: @partition["host"],
      source_client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"],
      subject_id: Ecto.UUID.generate(),
      subject_type: "memory",
      projector: "semantic",
      status: "pending",
      processing_version: "test-v1",
      input_revision: "source-r1"
    }

    %Backplane.Memory.Projections.State{}
    |> Ecto.Changeset.change(Map.merge(defaults, attrs))
    |> Backplane.Repo.insert!()
  end
end
