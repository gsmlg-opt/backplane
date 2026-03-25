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

  describe "format_origin/1" do
    test "formats native origin" do
      assert Utils.format_origin(:native) == "native"
    end

    test "formats upstream origin with prefix" do
      assert Utils.format_origin({:upstream, "my-server"}) == "upstream:my-server"
    end
  end
end
