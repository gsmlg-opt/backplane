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

  describe "format_origin/1" do
    test "formats native origin" do
      assert Utils.format_origin(:native) == "native"
    end

    test "formats upstream origin with prefix" do
      assert Utils.format_origin({:upstream, "my-server"}) == "upstream:my-server"
    end
  end
end
