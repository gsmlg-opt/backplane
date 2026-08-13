defmodule Backplane.Memory.ReplayMigrationInventoryTest do
  use ExUnit.Case, async: true

  @migration "20260812000020_preserve_replay_event_kind_identity.exs"

  test "keeps applied replay migration 00020 as a reversible schema-neutral marker" do
    path = Application.app_dir(:backplane_system, "priv/repo/migrations/#{@migration}")

    assert File.regular?(path)
    assert [{module, _binary}] = Code.compile_file(path)
    assert module == Backplane.Repo.Migrations.PreserveReplayEventKindIdentity

    assert apply(module, :up, []) == :ok
    assert apply(module, :down, []) == :ok
  end
end
