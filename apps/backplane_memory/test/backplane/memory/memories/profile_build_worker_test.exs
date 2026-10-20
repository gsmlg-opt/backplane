defmodule Backplane.Memory.Workers.ProfileBuildWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Projections.State
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.ProfileBuildWorker
  alias Backplane.MemorySpaces.BackfillIssue

  describe "rejected incoming profile requests" do
    test "a foreign project rejection leaves the requester's reads and edge partition ready" do
      project = "foreign-profile-#{System.unique_integer([:positive])}"
      source = insert_memory("source belongs to A", scope: project)
      requester = registered_partition()

      {:ok, own_memory} =
        Memories.remember("B remains readable", Map.to_list(requester) ++ [agent_id: "agent-b"])

      assert {:ok, _} =
               Backplane.MemorySpaces.resolve_host_partition(
                 requester.host_id,
                 requester.scope,
                 requester.namespace
               )

      issues_before = repo().all(from(i in BackfillIssue, order_by: i.id))

      Styx.Testing.with_testing_mode(:manual, fn ->
        assert {:error, :partition_mismatch} = ProfileBuildWorker.enqueue(project, requester)
        assert [] == Styx.Testing.all_enqueued(repo(), worker: ProfileBuildWorker)
      end)

      assert Backplane.MemorySpaces.partition_ready?(requester.host_id, requester)

      assert {:ok, _} =
               repo().transaction(fn ->
                 Backplane.Memory.EdgeSync.PostgresStore.authorize!(
                   requester.host_id,
                   stringify_keys(requester)
                 )
               end)

      assert [visible] = Memories.list([], requester)
      assert visible.id == own_memory.id
      refute visible.id == source.id
      assert repo().all(from(i in BackfillIssue, order_by: i.id)) == issues_before
      refute repo().exists?(Profile)
      refute repo().exists?(from(s in State, where: s.projector == "profile"))
    end

    test "an invalid or absent project request creates no migration ambiguity" do
      requester = canonical_partition("requester")
      issues_before = repo().all(from(i in BackfillIssue, order_by: i.id))

      assert {:error, :incomplete_partition} =
               ProfileBuildWorker.enqueue("absent", requester)

      assert {:error, :incomplete_partition} =
               ProfileBuildWorker.enqueue("absent", Map.delete(requester, :host_id))

      assert repo().all(from(i in BackfillIssue, order_by: i.id)) == issues_before
    end
  end

  defp insert_memory(content, opts) do
    metadata =
      opts |> Keyword.get(:metadata, %{}) |> Map.put_new("project", Keyword.fetch!(opts, :scope))

    opts = Keyword.put(opts, :metadata, metadata)

    defaults =
      [agent_id: "agent-1", host_id: "host-1", client_id: "host:host-1", namespace: "private"]

    {:ok, mem} =
      Memories.remember(
        content,
        canonical_memory_opts("host-1", Keyword.merge(defaults, opts))
      )

    mem
  end

  describe "waive_rejected_request_issue/3" do
    setup do
      project = "rejected-profile-#{System.unique_integer([:positive])}"
      insert_memory("foreign source", scope: project)
      requester = registered_partition()
      issue = historical_request_issue(project, requester)

      operator = %{
        kind: :trusted_operator,
        ref: "local-operator",
        request_id: Ecto.UUID.generate(),
        evidence_ref: "qualification/rejected-profile-request.json"
      }

      %{project: project, requester: requester, issue: issue, operator: operator}
    end

    test "waives only the exact attested request issue, retaining history and denial", c do
      refute Backplane.MemorySpaces.partition_ready?(c.requester.host_id, c.requester)

      assert {:ok, waived} = waive(c.issue, c.operator)
      assert waived.disposition == "approved_waiver"
      assert %DateTime{} = waived.resolved_at
      assert waived.details == c.issue.details
      assert waived.source_id == c.issue.source_id
      assert waived.inserted_at == c.issue.inserted_at
      assert Backplane.MemorySpaces.partition_ready?(c.requester.host_id, c.requester)

      assert {:ok, _} =
               repo().transaction(fn ->
                 Backplane.Memory.EdgeSync.PostgresStore.authorize!(
                   c.requester.host_id,
                   stringify_keys(c.requester)
                 )
               end)

      assert {:error, :partition_mismatch} =
               ProfileBuildWorker.enqueue(c.project, c.requester)

      assert repo().get!(BackfillIssue, c.issue.id).disposition == "approved_waiver"
      assert {:error, :issue_changed} = waive(c.issue, c.operator)

      assert [audit] = Backplane.Memory.Audit.list(operation: "memory.repair")
      assert audit.actor == c.operator.ref
      assert audit.target_ids == [c.issue.id]
      assert audit.metadata["evidence_ref"] == c.operator.evidence_ref
      assert audit.metadata["request_id"] == c.operator.request_id
      refute repo().exists?(Profile)
    end

    test "preserves unrelated and genuine persisted-data blockers", c do
      {:ok, legacy} =
        Memories.record_partition_issue(
          "bpm_memories",
          Ecto.UUID.generate(),
          :incomplete_partition,
          Map.put(c.requester, :namespace, "private")
        )

      {:ok, generator} =
        Memories.record_partition_issue(
          "memory_profile_generator",
          "genuine-worker-ambiguity",
          :incomplete_partition,
          c.requester
        )

      assert {:ok, _} = waive(c.issue, c.operator)
      assert repo().get!(BackfillIssue, legacy.id).disposition == "pending"
      assert repo().get!(BackfillIssue, generator.id).disposition == "pending"
      refute Backplane.MemorySpaces.partition_ready?(c.requester.host_id, c.requester)
      assert {:error, :not_rejected_request_issue} = waive(legacy, c.operator)
      assert {:error, :not_rejected_request_issue} = waive(generator, c.operator)
    end

    test "requires exact source, details, pending state, hash and reviewed operator evidence",
         c do
      for changed <- [
            %{source_id: "changed"},
            %{source_table: "bpm_memories"},
            %{reason: "incomplete_partition"},
            %{disposition: "resolved"},
            %{details: Map.put(c.issue.details, "scope", "other")},
            %{updated_at: DateTime.add(c.issue.updated_at, -1)}
          ] do
        assert {:error, :issue_changed} = waive(Map.merge(c.issue, changed), c.operator)
      end

      for invalid <- [%{}, %{c.operator | kind: :host_agent}, %{c.operator | evidence_ref: ""}] do
        assert {:error, :invalid_operator_attestation} = waive(c.issue, invalid)
      end

      changed = c.issue |> Ecto.Changeset.change(source_id: "wrong-hash") |> repo().update!()
      assert {:error, :not_rejected_request_issue} = waive(changed, c.operator)
      assert repo().get!(BackfillIssue, c.issue.id).disposition == "pending"
      assert [] == Backplane.Memory.Audit.list(operation: "memory.repair")
    end

    test "refuses an issue with persisted worker work for the claimed tuple", c do
      Styx.Testing.with_testing_mode(:manual, fn ->
        c.requester
        |> Map.put(:project, c.project)
        |> ProfileBuildWorker.new()
        |> Styx.insert!()

        assert {:error, :persisted_profile_work} = waive(c.issue, c.operator)
      end)

      assert repo().get!(BackfillIssue, c.issue.id).disposition == "pending"
    end

    test "refuses an issue if the claim now has real project sources", c do
      assert {:ok, _} =
               Memories.remember(
                 "now a real project source",
                 Map.to_list(c.requester) ++ [agent_id: "b", metadata: %{"project" => c.project}]
               )

      assert {:error, :not_rejected_request_issue} = waive(c.issue, c.operator)
      assert repo().get!(BackfillIssue, c.issue.id).disposition == "pending"
    end

    test "retired project sources still require persisted-data review", c do
      {:ok, memory} =
        Memories.remember(
          "retired source",
          Map.to_list(c.requester) ++ [agent_id: "b", metadata: %{"project" => c.project}]
        )

      assert :ok = Memories.forget(memory.id, c.requester)

      assert {:error, :persisted_profile_work} = waive(c.issue, c.operator)
      assert repo().get!(BackfillIssue, c.issue.id).disposition == "pending"
    end
  end

  describe "perform/1" do
    test "does not blend projects that share one authorization scope" do
      scope = "shared-scope-#{System.unique_integer([:positive])}"
      project = "project-a"

      insert_memory("owned", scope: scope, session_id: "owned", metadata: %{"project" => project})

      insert_memory("foreign",
        scope: scope,
        session_id: "foreign",
        metadata: %{"project" => "project-b"}
      )

      assert {:ok, :built} = ProfileBuildWorker.perform(job(project, scope))
      profile = Profiles.get(project, partition(scope))
      assert profile.total_observations == 1
      assert profile.source_records["session_ids"] == ["owned"]
    end

    test "does not blend summaries from another canonical subpartition" do
      project = "summary-partition-#{System.unique_integer([:positive])}"
      owner = partition(project)

      insert_memory("owned memory",
        scope: project,
        session_id: "shared-session",
        metadata: %{"project" => project}
      )

      owned_summary = insert_summary(owner, project, "owned summary")

      foreign =
        owner
        |> Map.put(:source_client_id, "foreign-client")
        |> Map.put(:namespace, "team:foreign")

      foreign_summary = insert_summary(foreign, project, "foreign summary")

      assert {:ok, :built} = ProfileBuildWorker.perform(job(project))
      profile = Profiles.get(project, owner)

      assert profile.source_records["summary_ids"] == [owned_summary.id]
      refute Map.has_key?(profile.recent_summaries, foreign_summary.id)
    end

    test "fails closed when generator provenance is incomplete" do
      partition = canonical_partition("profile-incomplete")

      for field <- [:memory_space_id, :host_id, :client_id, :scope, :namespace],
          invalid <- [nil, "", "   "] do
        incomplete = Map.put(partition, field, invalid)
        args = incomplete |> stringify_keys() |> Map.put("project", "incomplete")

        assert {:discard, :incomplete_partition} =
                 ProfileBuildWorker.perform(%Styx.Job{args: args})

        assert {:error, :incomplete_partition} =
                 ProfileBuildWorker.enqueue("incomplete", incomplete)
      end

      mismatched = Map.put(partition, "host_id", "other-host")
      mismatched_args = partition |> stringify_keys() |> Map.put(:host_id, "other-host")

      assert {:discard, :partition_mismatch} =
               ProfileBuildWorker.perform(%Styx.Job{
                 args: Map.put(mismatched_args, "project", "incomplete")
               })

      assert {:error, :partition_mismatch} =
               ProfileBuildWorker.enqueue("incomplete", mismatched)

      assert repo().aggregate(
               from(i in BackfillIssue,
                 where:
                   i.source_table == "memory_profile_generator" and
                     i.reason == "incomplete_partition" and i.disposition == "pending"
               ),
               :count
             ) >= 1
    end

    test "rejects complete claims that mismatch the authoritative project partition" do
      project = "authoritative-profile-#{System.unique_integer([:positive])}"
      authoritative = partition(project)
      insert_memory("authoritative source", scope: project, metadata: %{"project" => project})

      for {field, wrong} <- [
            memory_space_id: canonical_partition("other-profile").memory_space_id,
            host_id: "other-host",
            client_id: "other-client",
            scope: "other-scope",
            namespace: "team:other"
          ] do
        claim = Map.put(authoritative, field, wrong)

        assert {:discard, :partition_mismatch} =
                 ProfileBuildWorker.perform(%Styx.Job{
                   args: claim |> stringify_keys() |> Map.put("project", project)
                 })
      end

      assert repo().aggregate(from(p in Profile, where: p.project == ^project), :count) == 0
    end

    test "failure issue identity and details ignore unrelated profile job arguments" do
      project = "profile-redaction-#{System.unique_integer([:positive])}"
      insert_memory("profile authority", scope: project, metadata: %{"project" => project})

      wrong =
        project
        |> partition()
        |> Map.put(:namespace, "team:wrong")
        |> stringify_keys()
        |> Map.put("project", project)

      assert {:discard, :partition_mismatch} =
               ProfileBuildWorker.perform(%Styx.Job{args: wrong})

      [first] =
        repo().all(from(i in BackfillIssue, where: i.source_table == "memory_profile_generator"))

      assert {:discard, :partition_mismatch} =
               ProfileBuildWorker.perform(%Styx.Job{
                 args: Map.merge(wrong, %{"content" => "secret", "force" => true})
               })

      assert [%BackfillIssue{id: id, details: details}] =
               repo().all(
                 from(i in BackfillIssue, where: i.source_table == "memory_profile_generator")
               )

      assert id == first.id

      assert Map.keys(details) |> Enum.sort() ==
               ~w(client_id host_id memory_space_id namespace project scope)

      refute inspect(details) =~ "secret"
    end

    test "builds profile from fixture memories and upserts correctly" do
      project = "test-project-#{System.unique_integer([:positive])}"

      insert_memory("memory about elixir",
        scope: project,
        session_id: "session-1",
        tags: ["elixir", "otp"],
        metadata: %{"files" => ["lib/foo.ex", "lib/bar.ex"]}
      )

      insert_memory("memory about phoenix",
        scope: project,
        session_id: "session-1",
        tags: ["elixir", "phoenix"],
        metadata: %{"files" => ["lib/foo.ex"]}
      )

      insert_memory("memory about ecto",
        scope: project,
        session_id: "session-2",
        tags: ["ecto"],
        metadata: %{"files" => ["lib/repo.ex"]}
      )

      assert {:ok, :built} =
               ProfileBuildWorker.perform(job(project))

      profile = Profiles.get(project, partition(project))
      assert profile != nil
      assert profile.session_count == 2
      assert profile.total_observations == 3

      # "elixir" appears twice, otp/phoenix/ecto once each
      assert profile.top_concepts["elixir"] == 2
      assert profile.top_concepts["otp"] == 1
      assert profile.top_concepts["phoenix"] == 1
      assert profile.top_concepts["ecto"] == 1

      # "lib/foo.ex" appears twice, others once
      assert profile.top_files["lib/foo.ex"] == 2
      assert profile.top_files["lib/bar.ex"] == 1
      assert profile.top_files["lib/repo.ex"] == 1

      # all memories use default "semantic" type
      assert profile.patterns["semantic"] == 3
      assert profile.summary =~ "3 observations"
      assert profile.summary =~ "2 sessions"
      assert profile.source_records["memory_ids"] != []
      assert Enum.sort(profile.source_records["session_ids"]) == ["session-1", "session-2"]
      assert is_map(profile.active_lessons)
      assert is_map(profile.recent_crystals)
      assert is_map(profile.recent_summaries)
    end

    test "input revision changes only when canonical profile sources change" do
      project = "profile-source-revision-#{System.unique_integer([:positive])}"
      insert_memory("first source", scope: project, metadata: %{"project" => project})

      assert {:ok, :built} = ProfileBuildWorker.perform(job(project))
      first = repo().get_by!(State, projector: "profile").input_revision

      assert {:ok, :cached} = ProfileBuildWorker.perform(job(project))
      assert repo().get_by!(State, projector: "profile").input_revision == first

      insert_memory("second source", scope: project, metadata: %{"project" => project})
      forced = update_in(job(project).args, &Map.put(&1, "force", true))

      assert {:ok, :built} = ProfileBuildWorker.perform(forced)
      refute repo().get_by!(State, projector: "profile").input_revision == first
    end

    test "a source committed during profile generation rejects the stale profile build" do
      project = "profile-revision-race-#{System.unique_integer([:positive])}"
      insert_memory("profile R1", scope: project, metadata: %{"project" => project})
      parent = self()

      old_task =
        Task.async(fn ->
          receive do
            :start_profile_build -> :ok
          end

          Process.put({ProfileBuildWorker, :persistence_gate}, parent)
          ProfileBuildWorker.perform(job(project))
        end)

      Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), old_task.pid)
      send(old_task.pid, :start_profile_build)
      old_task_pid = old_task.pid

      assert_receive {:profile_ready_to_persist, ^old_task_pid}, 5_000

      try do
        assert %State{status: "running", input_revision: r1_revision} =
                 repo().get_by!(State, projector: "profile")

        insert_memory("profile R2", scope: project, metadata: %{"project" => project})
        send(old_task.pid, :continue_profile_persistence)
        assert {:discard, :stale} = Task.await(old_task, 5_000)
        refute Profiles.get(project, partition(project))

        assert {:ok, :built} = ProfileBuildWorker.perform(job(project))
        profile = Profiles.get(project, partition(project))
        assert profile.total_observations == 2

        assert %State{status: "complete", input_revision: r2_revision} =
                 repo().get_by!(State, projector: "profile")

        refute r2_revision == r1_revision
      after
        if Process.alive?(old_task.pid), do: send(old_task.pid, :continue_profile_persistence)
      end
    end

    test "input revision ignores lessons outside the exact profile scope" do
      scope = "profile-scope-#{System.unique_integer([:positive])}"
      project = "profile-project-#{System.unique_integer([:positive])}"
      insert_memory("owned source", scope: scope, metadata: %{"project" => project})

      assert {:ok, :built} = ProfileBuildWorker.perform(job(project, scope))
      revision = repo().get_by!(State, projector: "profile").input_revision

      foreign = insert_memory("foreign lesson", scope: project, metadata: %{"project" => project})

      repo().insert!(%Lesson{
        memory_id: foreign.id,
        status: "active",
        source_kind: "manual",
        reinforcement_count: 0,
        contradiction_count: 0,
        decay_rate: 0.0
      })

      forced = update_in(job(project, scope).args, &Map.put(&1, "force", true))
      assert {:ok, :built} = ProfileBuildWorker.perform(forced)
      assert repo().get_by!(State, projector: "profile").input_revision == revision
    end

    test "records retryable failure before dead-lettering the final attempt" do
      project = "profile-dead-letter-#{System.unique_integer([:positive])}"
      insert_memory("source", scope: project, metadata: %{"project" => project})
      constraint = "memory_profiles_test_reject_task15"

      repo().query!(
        "ALTER TABLE memory_profiles ADD CONSTRAINT #{constraint} CHECK (project <> '#{project}')"
      )

      try do
        assert_raise Ecto.ConstraintError, fn ->
          ProfileBuildWorker.perform(%{job(project) | attempt: 1, max_attempts: 3})
        end

        assert %State{status: "failed"} = repo().get_by!(State, projector: "profile")

        assert_raise Ecto.ConstraintError, fn ->
          ProfileBuildWorker.perform(%{job(project) | attempt: 3, max_attempts: 3})
        end

        assert %State{status: "dead_letter"} = repo().get_by!(State, projector: "profile")
      after
        repo().query!("ALTER TABLE memory_profiles DROP CONSTRAINT #{constraint}")
      end
    end

    test "upserts on second build, replacing previous values" do
      project = "test-upsert-#{System.unique_integer([:positive])}"

      insert_memory("first memory",
        scope: project,
        session_id: "s1",
        tags: ["tag-a"]
      )

      # Insert stale profile so TTL does not block the second build
      repo().insert!(%Profile{
        project: project,
        memory_space_id: canonical_partition("host-1", scope: project).memory_space_id,
        host_id: "host-1",
        client_id: "host:host-1",
        source_client_id: "host:host-1",
        scope: project,
        namespace: "private",
        top_concepts: %{},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      })

      ProfileBuildWorker.perform(job(project))
      first_profile = Profiles.get(project, partition(project))
      assert first_profile.total_observations == 1

      insert_memory("second memory",
        scope: project,
        session_id: "s2",
        tags: ["tag-b"]
      )

      # Mark profile stale again so second perform rebuilds
      repo().update_all(
        from(p in Profile, where: p.project == ^project),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -7200, :second)]
      )

      ProfileBuildWorker.perform(job(project))
      second_profile = Profiles.get(project, partition(project))
      assert second_profile.total_observations == 2
    end

    test "respects TTL: returns {:ok, :cached} when updated_at is within the last hour" do
      project = "test-ttl-#{System.unique_integer([:positive])}"

      # Directly insert a fresh profile (updated less than 1 hour ago)
      repo().insert!(%Profile{
        project: project,
        memory_space_id: canonical_partition("host-1", scope: project).memory_space_id,
        host_id: "host-1",
        client_id: "host:host-1",
        source_client_id: "host:host-1",
        scope: project,
        namespace: "private",
        top_concepts: %{"cached" => 1},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: DateTime.utc_now()
      })

      assert {:ok, :cached} =
               ProfileBuildWorker.perform(job(project))
    end

    test "rebuilds when updated_at is older than 1 hour" do
      project = "test-ttl-stale-#{System.unique_integer([:positive])}"

      stale_time = DateTime.add(DateTime.utc_now(), -3700, :second)

      repo().insert!(%Profile{
        project: project,
        memory_space_id: canonical_partition("host-1", scope: project).memory_space_id,
        host_id: "host-1",
        client_id: "host:host-1",
        source_client_id: "host:host-1",
        scope: project,
        namespace: "private",
        top_concepts: %{"old" => 1},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: stale_time
      })

      assert {:ok, :built} =
               ProfileBuildWorker.perform(job(project))

      profile = Profiles.get(project, partition(project))
      # After rebuild, stale "old" concept should be gone (no memories exist)
      assert profile.top_concepts == %{}
    end
  end

  describe "get_or_build/2" do
    test "returns the enqueue error without an authoritative project source" do
      project = "test-build-trigger-#{System.unique_integer([:positive])}"

      Styx.Testing.with_testing_mode(:manual, fn ->
        assert {:error, :incomplete_partition} =
                 Profiles.get_or_build(project, partition(project))

        Styx.Testing.refute_enqueued(repo(),
          worker: ProfileBuildWorker,
          args: %{"project" => project}
        )
      end)
    end

    test "returns {:building, nil} and enqueues when the project source exists" do
      project = "test-build-source-#{System.unique_integer([:positive])}"
      source = insert_memory("profile source", scope: project)

      Styx.Testing.with_testing_mode(:manual, fn ->
        assert {:building, nil} = Profiles.get_or_build(project, partition(project))

        assert Styx.Testing.assert_enqueued(repo(),
                 worker: ProfileBuildWorker,
                 args: %{"project" => project, "memory_space_id" => source.memory_space_id}
               )
      end)
    end

    test "returns {:ok, profile} when profile already exists" do
      project = "test-cached-profile-#{System.unique_integer([:positive])}"

      repo().insert!(%Profile{
        project: project,
        memory_space_id: canonical_partition("host-1", scope: project).memory_space_id,
        host_id: "host-1",
        client_id: "host:host-1",
        source_client_id: "host:host-1",
        scope: project,
        namespace: "private",
        top_concepts: %{"foo" => 3},
        top_files: %{},
        patterns: %{},
        session_count: 1,
        total_observations: 5,
        updated_at: DateTime.utc_now()
      })

      assert {:ok, profile} = Profiles.get_or_build(project, partition(project))
      assert profile.project == project
      assert profile.total_observations == 5
    end
  end

  defp partition(project) do
    canonical_partition("host-1", client_id: "host:host-1", scope: project)
  end

  defp registered_partition do
    host_id = Ecto.UUID.generate()
    scope = "profile-requester-#{host_id}"

    repo().query!(
      "INSERT INTO skill_hosts(id,name,memory_scope,inserted_at,updated_at) VALUES($1,$2,$3,now(),now())",
      [Ecto.UUID.dump!(host_id), "profile-requester-#{host_id}", scope]
    )

    {:ok, partition} = Backplane.MemorySpaces.provision_private_host(host_id, scope)
    Map.merge(partition, %{host_id: host_id, client_id: "host:#{host_id}"})
  end

  defp historical_request_issue(project, requester) do
    claim = Map.take(requester, [:memory_space_id, :host_id, :client_id, :scope, :namespace])

    source_id =
      :crypto.hash(:sha256, :erlang.term_to_binary([project, claim], [:deterministic]))
      |> Base.encode16(case: :lower)

    {:ok, issue} =
      Memories.record_partition_issue(
        "memory_profile_generator",
        source_id,
        :partition_mismatch,
        Map.put(claim, :project, project)
      )

    repo().get!(BackfillIssue, issue.id)
  end

  defp waive(issue, operator) do
    expected =
      Map.take(issue, [:source_table, :source_id, :reason, :disposition, :details, :updated_at])

    apply(ProfileBuildWorker, :waive_rejected_request_issue, [issue.id, expected, operator])
  end

  defp job(project, scope \\ nil) do
    args =
      partition(scope || project)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("project", project)

    %Styx.Job{args: args}
  end

  defp insert_summary(partition, project, content) do
    revision = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Summary{}
    |> Summary.changeset(
      Map.merge(partition, %{
        session_id: "shared-session",
        project: project,
        content: content,
        subject_id: "profile:#{revision}",
        processing_version: "summary-v1",
        input_revision: revision,
        output_revision: revision
      })
    )
    |> repo().insert!()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
