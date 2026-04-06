defmodule Backplane.Audit.PrunerTest do
  use Backplane.DataCase, async: true
  use Oban.Testing, repo: Backplane.Repo

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}

  describe "perform/1" do
    test "deletes tool_call_log rows older than retention" do
      old_time = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

      Repo.insert!(%ToolCallLog{
        tool_name: "old-tool",
        status: "ok",
        inserted_at: old_time
      })

      Repo.insert!(%ToolCallLog{
        tool_name: "new-tool",
        status: "ok",
        inserted_at: DateTime.utc_now()
      })

      assert :ok = perform_job(Backplane.Audit.Pruner, %{})

      logs = Repo.all(ToolCallLog)
      assert length(logs) == 1
      assert hd(logs).tool_name == "new-tool"
    end

    test "deletes skill_load_log rows older than retention" do
      old_time = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

      Repo.insert!(%SkillLoadLog{
        skill_name: "old-skill",
        inserted_at: old_time
      })

      Repo.insert!(%SkillLoadLog{
        skill_name: "new-skill",
        inserted_at: DateTime.utc_now()
      })

      assert :ok = perform_job(Backplane.Audit.Pruner, %{})

      logs = Repo.all(SkillLoadLog)
      assert length(logs) == 1
      assert hd(logs).skill_name == "new-skill"
    end

    test "retains rows within retention window" do
      recent_time = DateTime.utc_now() |> DateTime.add(-5 * 86_400, :second)

      Repo.insert!(%ToolCallLog{
        tool_name: "recent-tool",
        status: "ok",
        inserted_at: recent_time
      })

      Repo.insert!(%SkillLoadLog{
        skill_name: "recent-skill",
        inserted_at: recent_time
      })

      assert :ok = perform_job(Backplane.Audit.Pruner, %{})

      assert Repo.aggregate(ToolCallLog, :count) == 1
      assert Repo.aggregate(SkillLoadLog, :count) == 1
    end

    test "handles empty tables gracefully" do
      assert Repo.aggregate(ToolCallLog, :count) == 0
      assert Repo.aggregate(SkillLoadLog, :count) == 0

      assert :ok = perform_job(Backplane.Audit.Pruner, %{})
    end
  end
end
