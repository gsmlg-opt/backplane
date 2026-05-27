defmodule BackplaneTest do
  use Backplane.DataCase, async: true

  describe "public API" do
    test "list_tools returns a list" do
      assert is_list(Backplane.list_tools())
    end

    test "tool_count returns a non-negative integer" do
      assert is_integer(Backplane.tool_count())
      assert Backplane.tool_count() >= 0
    end

    test "search_skills returns a list" do
      assert is_list(Backplane.search_skills("test"))
    end

    test "skill_count returns a non-negative integer" do
      assert is_integer(Backplane.skill_count())
      assert Backplane.skill_count() >= 0
    end

    test "version returns a string" do
      assert is_binary(Backplane.version())
      assert Backplane.version() =~ ~r/^\d+\.\d+\.\d+$/
    end

    test "protocol_version returns a date string" do
      assert is_binary(Backplane.protocol_version())
      assert Backplane.protocol_version() =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end

    test "discover delegates to Hub.Discover" do
      assert {:ok, results} = Backplane.discover("test")
      assert is_map(results)
    end


  end
end
