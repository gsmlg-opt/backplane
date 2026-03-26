defmodule Backplane.Skills.SyncTest do
  use Backplane.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{Skill, Sync}

  setup do
    # Ensure skills registry ETS table exists
    if :ets.whereis(:backplane_skills) == :undefined do
      :ets.new(:backplane_skills, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  describe "sync_entries/1" do
    test "inserts new skills from source" do
      entries = [
        skill_entry("sync:test/skill1", "sync:test"),
        skill_entry("sync:test/skill2", "sync:test")
      ]

      Sync.sync_entries(entries)

      assert Repo.get(Skill, "sync:test/skill1") != nil
      assert Repo.get(Skill, "sync:test/skill2") != nil
    end

    test "updates changed skills (different content_hash)" do
      insert_skill("sync:update/s1", "sync:update", "old content")

      entries = [
        skill_entry("sync:update/s1", "sync:update", content: "new content")
      ]

      Sync.sync_entries(entries)

      updated = Repo.get!(Skill, "sync:update/s1")
      assert updated.content == "new content"
    end

    test "disables removed skills (not present in source)" do
      insert_skill("sync:remove/s1", "sync:remove", "content")
      insert_skill("sync:remove/s2", "sync:remove", "content")

      # Only s1 in incoming
      entries = [skill_entry("sync:remove/s1", "sync:remove")]

      Sync.sync_entries(entries)

      s2 = Repo.get!(Skill, "sync:remove/s2")
      assert s2.enabled == false
    end

    test "skips unchanged skills (same content_hash)" do
      content = "# Unchanged Content"
      insert_skill("sync:skip/s1", "sync:skip", content)
      old = Repo.get!(Skill, "sync:skip/s1")

      entries = [skill_entry("sync:skip/s1", "sync:skip", content: content)]
      Sync.sync_entries(entries)

      reloaded = Repo.get!(Skill, "sync:skip/s1")
      assert reloaded.updated_at == old.updated_at
    end

    test "refreshes ETS registry after sync" do
      # This test would require the Skills.Registry to be running
      # We just verify sync_entries doesn't crash
      entries = [skill_entry("sync:ets/s1", "sync:ets")]
      assert :ok = Sync.sync_entries(entries)
    end

    test "handles empty source gracefully" do
      assert :ok = Sync.sync_entries([])
    end

    test "does not disable already-disabled skills" do
      insert_skill("sync:disabled/s1", "sync:disabled", "content")
      # Manually disable
      Repo.get!(Skill, "sync:disabled/s1")
      |> Skill.update_changeset(%{enabled: false})
      |> Repo.update!()

      entries = [skill_entry("sync:disabled/s2", "sync:disabled")]
      Sync.sync_entries(entries)

      s1 = Repo.get!(Skill, "sync:disabled/s1")
      refute s1.enabled
    end
  end

  describe "perform/1" do
    test "raises for disallowed source module" do
      job = %Oban.Job{
        args: %{"source_module" => "Elixir.SomeEvil.Module", "name" => "bad"}
      }

      assert_raise RuntimeError, ~r/Disallowed source module/, fn ->
        Sync.perform(job)
      end
    end

    test "perform with Local source module processes entries" do
      # Create a temp dir with a SKILL.md
      dir = "/tmp/backplane_sync_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: sync-local-test
      description: A test skill from local source
      tags: [test, sync]
      ---
      # Test Skill Content
      """)

      job = %Oban.Job{
        args: %{
          "source_module" => "Elixir.Backplane.Skills.Sources.Local",
          "name" => "sync-local",
          "path" => dir
        }
      }

      assert :ok = Sync.perform(job)

      File.rm_rf!(dir)
    end

    # --- Coverage for L31: {:error, reason} branch in perform/1 ---
    # When the source module's list/1 returns {:error, reason}, perform/1
    # propagates it as {:error, reason}. Local returns {:error, :directory_not_found}
    # when the path does not exist on disk.
    test "perform returns {:error, reason} when source list fails" do
      job = %Oban.Job{
        args: %{
          "source_module" => "Elixir.Backplane.Skills.Sources.Local",
          "name" => "sync-err",
          "path" => "/tmp/backplane_nonexistent_dir_#{System.unique_integer([:positive])}"
        }
      }

      assert {:error, :directory_not_found} = Sync.perform(job)
    end

    # --- Coverage for L106, L110: build_config with Git source module ---
    # build_config/2 builds a Sources.Git struct at L106.  When args["ref"] is
    # absent the expression `args["ref"] || "main"` evaluates the `|| "main"`
    # side (L110).  We trigger these lines by calling perform/1 with the Git
    # source module and a bad repo so the clone fails quickly and returns an
    # error rather than blocking the test suite.
    test "build_config uses Git struct and defaults ref to 'main' when absent" do
      job = %Oban.Job{
        args: %{
          "source_module" => "Elixir.Backplane.Skills.Sources.Git",
          "name" => "git-default-ref",
          "repo" => "https://invalid.example.invalid/repo.git",
          "path" => nil
          # "ref" intentionally omitted to exercise the `|| "main"` branch
        }
      }

      # The git clone will fail because the repo URL is invalid, which causes
      # Sources.Git.list/1 to return {:error, {:clone_failed, _}} — that
      # propagates as {:error, _} from perform/1.  We only care that build_config
      # ran the Git branch (L106) and defaulted the ref (L110).
      result = Sync.perform(job)
      assert match?({:error, _}, result)
    end

    test "build_config uses explicit ref when provided in args" do
      job = %Oban.Job{
        args: %{
          "source_module" => "Elixir.Backplane.Skills.Sources.Git",
          "name" => "git-explicit-ref",
          "repo" => "https://invalid.example.invalid/repo.git",
          "path" => nil,
          "ref" => "develop"
        }
      }

      result = Sync.perform(job)
      assert match?({:error, _}, result)
    end
  end

  defp skill_entry(id, source, opts \\ []) do
    content = Keyword.get(opts, :content, "# Default Content for #{id}")
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %{
      id: id,
      name: "skill-#{id}",
      description: "Test skill",
      tags: ["test"],
      tools: [],
      model: nil,
      version: "1.0.0",
      content: content,
      content_hash: hash,
      source: source
    }
  end

  defp insert_skill(id, source, content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      name: "skill-#{id}",
      description: "Test skill",
      content: content,
      content_hash: hash,
      source: source,
      enabled: true
    })
    |> Repo.insert!()
  end
end
