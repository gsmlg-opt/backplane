defmodule MathEx.MixProjectTest do
  use ExUnit.Case, async: true

  test "ignores stale beam module conflicts during recompilation" do
    assert MathEx.MixProject.project()[:elixirc_options][:ignore_module_conflict]
  end
end
