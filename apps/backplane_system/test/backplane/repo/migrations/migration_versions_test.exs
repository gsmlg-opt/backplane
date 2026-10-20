defmodule Backplane.Repo.Migrations.MigrationVersionsTest do
  use ExUnit.Case, async: true

  test "executable migrations have unique versions across merged feature histories" do
    duplicates =
      "../../../../priv/repo/migrations/*.exs"
      |> Path.expand(__DIR__)
      |> Path.wildcard()
      |> Enum.group_by(&(&1 |> Path.basename() |> String.split("_", parts: 2) |> hd()))
      |> Enum.filter(fn {_version, files} -> length(files) > 1 end)

    assert duplicates == []
  end
end
