defmodule Backplane.Proxy.NamespaceTest do
  use ExUnit.Case, async: true

  alias Backplane.Proxy.Namespace

  describe "prefix/2" do
    test "prefixes tool name with separator" do
      assert Namespace.prefix("fs", "read_file") == "fs::read_file"
    end

    test "handles empty tool name" do
      assert Namespace.prefix("fs", "") == "fs::"
    end

    test "handles tool name already containing ::" do
      assert Namespace.prefix("fs", "sub::tool") == "fs::sub::tool"
    end
  end

  describe "strip/2" do
    test "removes prefix to recover original name" do
      assert Namespace.strip("fs", "fs::read_file") == "read_file"
    end

    test "returns original if no prefix match" do
      assert Namespace.strip("pg", "fs::read_file") == "fs::read_file"
    end
  end

  describe "extract_namespace/1" do
    test "extracts namespace from namespaced name" do
      assert Namespace.extract_namespace("fs::read_file") == {:ok, "fs"}
    end

    test "returns error for non-namespaced name" do
      assert Namespace.extract_namespace("plain_tool") == :error
    end
  end
end
