defmodule BackplaneMemory.Workers.ProfileBuildWorkerTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Memory
  alias BackplaneMemory.Memories.{Profile, Profiles}
  alias BackplaneMemory.Workers.ProfileBuildWorker

  defp insert_memory(content, opts \\ []) do
    defaults = [agent_id: "agent-1", host_id: "host-1"]
    {:ok, mem} = Memory.remember(content, Keyword.merge(defaults, opts))
    mem
  end

  describe "perform/1" do
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
               ProfileBuildWorker.perform(%Oban.Job{args: %{"project" => project}})

      profile = repo().get(Profile, project)
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
        top_concepts: %{},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      })

      ProfileBuildWorker.perform(%Oban.Job{args: %{"project" => project}})
      first_profile = repo().get(Profile, project)
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

      ProfileBuildWorker.perform(%Oban.Job{args: %{"project" => project}})
      second_profile = repo().get(Profile, project)
      assert second_profile.total_observations == 2
    end

    test "respects TTL: returns {:ok, :cached} when updated_at is within the last hour" do
      project = "test-ttl-#{System.unique_integer([:positive])}"

      # Directly insert a fresh profile (updated less than 1 hour ago)
      repo().insert!(%Profile{
        project: project,
        top_concepts: %{"cached" => 1},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: DateTime.utc_now()
      })

      assert {:ok, :cached} =
               ProfileBuildWorker.perform(%Oban.Job{args: %{"project" => project}})
    end

    test "rebuilds when updated_at is older than 1 hour" do
      project = "test-ttl-stale-#{System.unique_integer([:positive])}"

      stale_time = DateTime.add(DateTime.utc_now(), -3700, :second)

      repo().insert!(%Profile{
        project: project,
        top_concepts: %{"old" => 1},
        top_files: %{},
        patterns: %{},
        session_count: 0,
        total_observations: 0,
        updated_at: stale_time
      })

      assert {:ok, :built} =
               ProfileBuildWorker.perform(%Oban.Job{args: %{"project" => project}})

      profile = repo().get(Profile, project)
      # After rebuild, stale "old" concept should be gone (no memories exist)
      assert profile.top_concepts == %{}
    end
  end

  describe "get_or_build/1" do
    test "returns {:building, nil} and enqueues job when no profile exists" do
      project = "test-build-trigger-#{System.unique_integer([:positive])}"
      assert {:building, nil} = Profiles.get_or_build(project)
    end

    test "returns {:ok, profile} when profile already exists" do
      project = "test-cached-profile-#{System.unique_integer([:positive])}"

      repo().insert!(%Profile{
        project: project,
        top_concepts: %{"foo" => 3},
        top_files: %{},
        patterns: %{},
        session_count: 1,
        total_observations: 5,
        updated_at: DateTime.utc_now()
      })

      assert {:ok, profile} = Profiles.get_or_build(project)
      assert profile.project == project
      assert profile.total_observations == 5
    end
  end
end
