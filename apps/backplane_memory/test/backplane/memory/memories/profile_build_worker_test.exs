defmodule Backplane.Memory.Workers.ProfileBuildWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Workers.ProfileBuildWorker

  defp insert_memory(content, opts) do
    metadata =
      opts |> Keyword.get(:metadata, %{}) |> Map.put_new("project", Keyword.fetch!(opts, :scope))

    opts = Keyword.put(opts, :metadata, metadata)

    defaults =
      [agent_id: "agent-1", host_id: "host-1", client_id: "host:host-1", namespace: "private"]

    {:ok, mem} = Memories.remember(content, Keyword.merge(defaults, opts))
    mem
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
        host_id: "host-1",
        client_id: "host:host-1",
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
        host_id: "host-1",
        client_id: "host:host-1",
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
        host_id: "host-1",
        client_id: "host:host-1",
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
    test "returns {:building, nil} and enqueues job when no profile exists" do
      project = "test-build-trigger-#{System.unique_integer([:positive])}"
      assert {:building, nil} = Profiles.get_or_build(project, partition(project))
    end

    test "returns {:ok, profile} when profile already exists" do
      project = "test-cached-profile-#{System.unique_integer([:positive])}"

      repo().insert!(%Profile{
        project: project,
        host_id: "host-1",
        client_id: "host:host-1",
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
    %{host_id: "host-1", client_id: "host:host-1", scope: project, namespace: "private"}
  end

  defp job(project, scope \\ nil) do
    args =
      partition(scope || project)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("project", project)

    %Oban.Job{args: args}
  end
end
