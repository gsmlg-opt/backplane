defmodule Backplane.Audit.ToolCallLogTest do
  use Backplane.DataCase, async: true

  alias Backplane.Audit.ToolCallLog

  describe "changeset" do
    test "valid with required fields (tool_name, status)" do
      cs =
        ToolCallLog.changeset(%ToolCallLog{}, %{
          tool_name: "docs::query-docs",
          status: "ok"
        })

      assert cs.valid?
      assert get_change(cs, :tool_name) == "docs::query-docs"
      assert get_change(cs, :status) == "ok"
    end

    test "allows nullable client_id" do
      cs =
        ToolCallLog.changeset(%ToolCallLog{}, %{
          tool_name: "git::repo-tree",
          status: "ok",
          client_id: nil
        })

      assert cs.valid?
      assert get_change(cs, :client_id) == nil
    end

    test "stores arguments_hash not arguments (verify no arguments field exists)" do
      fields = ToolCallLog.__schema__(:fields)
      refute :arguments in fields
      assert :arguments_hash in fields

      cs =
        ToolCallLog.changeset(%ToolCallLog{}, %{
          tool_name: "docs::query-docs",
          status: "ok",
          arguments_hash: "abc123"
        })

      assert cs.valid?
      assert get_change(cs, :arguments_hash) == "abc123"
    end
  end
end
