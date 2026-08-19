defmodule Backplane.Registry.NamespaceTest do
  use ExUnit.Case, async: true

  alias Backplane.Registry.Namespace

  describe "reserved prefixes" do
    test "reserves only the built-in skill namespace" do
      assert Namespace.reserved_prefixes() == ["skill"]
      assert Namespace.reserved_prefix?("skill")
      assert Namespace.reserved_prefix?(" /skill/ ")
      refute Namespace.reserved_prefix?("github")
    end
  end
end
