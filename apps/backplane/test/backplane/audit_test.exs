defmodule Backplane.AuditTest do
  use Backplane.DataCase, async: true

  alias Backplane.Audit
  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}

  describe "log_tool_call/1" do
    test "inserts tool call log with metadata" do
      Audit.log_tool_call(%{
        tool_name: "docs::query-docs",
        status: "ok",
        duration_us: 5000,
        arguments_hash: Audit.hash_arguments(%{"query" => "test"}),
        client_name: "test-client"
      })

      logs = Repo.all(ToolCallLog)
      assert length(logs) == 1
      assert hd(logs).tool_name == "docs::query-docs"
      assert hd(logs).status == "ok"
      assert hd(logs).duration_us == 5000
    end

    test "records duration from attrs" do
      Audit.log_tool_call(%{
        tool_name: "git::repo-tree",
        status: "ok",
        duration_us: 12345
      })

      log = Repo.one!(ToolCallLog)
      assert log.duration_us == 12345
    end

    test "records error status and message on failure" do
      Audit.log_tool_call(%{
        tool_name: "git::repo-tree",
        status: "error",
        error_message: "upstream timeout",
        duration_us: 30000
      })

      log = Repo.one!(ToolCallLog)
      assert log.status == "error"
      assert log.error_message == "upstream timeout"
    end

    test "records client_name when present" do
      Audit.log_tool_call(%{
        tool_name: "docs::query-docs",
        status: "ok",
        client_name: "my-agent"
      })

      log = Repo.one!(ToolCallLog)
      assert log.client_name == "my-agent"
    end
  end

  describe "log_skill_load/1" do
    test "inserts skill load log with metadata" do
      Audit.log_skill_load(%{
        skill_name: "elixir-review",
        client_name: "test-client",
        loaded_deps: ["base-lib", "formatter"]
      })

      logs = Repo.all(SkillLoadLog)
      assert length(logs) == 1
      assert hd(logs).skill_name == "elixir-review"
      assert hd(logs).client_name == "test-client"
      assert hd(logs).loaded_deps == ["base-lib", "formatter"]
    end
  end
end
