defmodule Backplane.ReleaseTest do
  use ExUnit.Case, async: true

  test "exposes the release migration command" do
    assert {:module, Backplane.Release} = Code.ensure_loaded(Backplane.Release)
    assert function_exported?(Backplane.Release, :migrate, 0)
    assert Application.fetch_env!(:backplane_system, :ecto_repos) == [Backplane.Repo]
  end

  test "routes the migrate release command through env.sh" do
    env_script = File.read!(Path.expand("../../../../rel/env.sh.eex", __DIR__))

    assert env_script =~ ~s(case "$RELEASE_COMMAND")
    assert env_script =~ "RELEASE_ROOT/bin/$RELEASE_NAME"
    assert env_script =~ "Backplane.Release.migrate()"
  end
end
