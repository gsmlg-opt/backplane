defmodule Backplane.Memory.RecordsListTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{AdminQueries, Records}

  defp mk(attrs), do: Records.remember(Map.merge(%{"content" => "c", "writer" => "agent"}, attrs))

  test "list/1 returns active records newest-first and honors filters" do
    {:ok, old} =
      mk(%{"content" => "old", "observed_at" => ~U[2026-01-01 00:00:00Z], "host_id" => "h1"})

    {:ok, new} =
      mk(%{
        "content" => "new",
        "observed_at" => ~U[2026-02-01 00:00:00Z],
        "host_id" => "h2",
        "kind" => "worklog"
      })

    {:ok, gone} = mk(%{"content" => "gone", "host_id" => "h1"})
    {:ok, _} = Records.forget(gone.id, "x")

    assert [new.id, old.id] == Enum.map(Records.list(), & &1.id)
    assert [old.id] == Enum.map(Records.list(%{"host_id" => "h1"}), & &1.id)
    assert [new.id] == Enum.map(Records.list(%{"kind" => "worklog"}), & &1.id)
    assert length(Records.list(%{"include_inactive" => true})) == 3
    assert [new.id] == Enum.map(Records.list(%{"since" => "2026-01-15T00:00:00Z"}), & &1.id)
    assert_raise ArgumentError, fn -> Records.list(%{"limit" => -1}) end
    assert_raise ArgumentError, fn -> Records.list(%{"since" => "nope"}) end
  end

  test "record_counts/0 groups by kind and status" do
    {:ok, _} = mk(%{})
    {:ok, r} = mk(%{})
    {:ok, _} = Records.forget(r.id, "x")
    counts = AdminQueries.record_counts()
    assert counts[{"note", "active"}] == 1
    assert counts[{"note", "forgotten"}] == 1
  end
end
