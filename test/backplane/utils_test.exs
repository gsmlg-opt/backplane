defmodule Backplane.UtilsTest do
  use ExUnit.Case, async: true

  alias Backplane.Utils

  describe "maybe_put/3" do
    test "adds key-value pair when value is not nil" do
      assert Utils.maybe_put([], :key, "value") == [key: "value"]
    end

    test "returns list unchanged when value is nil" do
      assert Utils.maybe_put([existing: true], :key, nil) == [existing: true]
    end

    test "overwrites existing key" do
      assert Utils.maybe_put([key: "old"], :key, "new") == [key: "new"]
    end

    test "keeps false values" do
      assert Utils.maybe_put([], :enabled, false) == [enabled: false]
    end

    test "keeps empty string values" do
      assert Utils.maybe_put([], :name, "") == [name: ""]
    end

    test "keeps empty list values" do
      assert Utils.maybe_put([], :tags, []) == [tags: []]
    end
  end

  describe "escape_like/1" do
    test "escapes percent wildcard" do
      assert Utils.escape_like("100%") == "100\\%"
    end

    test "escapes underscore wildcard" do
      assert Utils.escape_like("my_project") == "my\\_project"
    end

    test "escapes backslash" do
      assert Utils.escape_like("path\\to") == "path\\\\to"
    end

    test "escapes all wildcards in mixed input" do
      assert Utils.escape_like("a%b_c\\d") == "a\\%b\\_c\\\\d"
    end

    test "returns plain strings unchanged" do
      assert Utils.escape_like("hello world") == "hello world"
    end
  end

  describe "parse_interval/1" do
    test "parses seconds" do
      assert {:ok, 30} = Utils.parse_interval("30s")
    end

    test "parses minutes" do
      assert {:ok, 1800} = Utils.parse_interval("30m")
    end

    test "parses hours" do
      assert {:ok, 3600} = Utils.parse_interval("1h")
    end

    test "parses days" do
      assert {:ok, 172_800} = Utils.parse_interval("2d")
    end

    test "returns error for unknown suffix" do
      assert :error = Utils.parse_interval("10x")
    end

    test "returns error for zero" do
      assert :error = Utils.parse_interval("0h")
    end

    test "returns error for negative" do
      assert :error = Utils.parse_interval("-1h")
    end

    test "returns error for non-binary" do
      assert :error = Utils.parse_interval(42)
    end

    test "returns error for empty string" do
      assert :error = Utils.parse_interval("")
    end
  end

  describe "format_origin/1" do
    test "formats native origin" do
      assert Utils.format_origin(:native) == "native"
    end

    test "formats upstream origin with prefix" do
      assert Utils.format_origin({:upstream, "my-server"}) == "upstream:my-server"
    end

    test "raises on unknown origin" do
      assert_raise FunctionClauseError, fn ->
        # Use binary_to_atom to bypass compile-time type check
        origin = String.to_atom("unknown")
        Utils.format_origin(origin)
      end
    end
  end
end
