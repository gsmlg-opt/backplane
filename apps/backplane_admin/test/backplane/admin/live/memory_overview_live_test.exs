defmodule Backplane.Admin.MemoryOverviewLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Distillation

  defp seed(status) do
    now = DateTime.utc_now()

    Backplane.Repo.insert!(%Distillation{
      subject_id: "ov-#{status}-#{System.unique_integer([:positive])}",
      status: status,
      mode: "distill",
      last_error: "boom",
      due_at: now,
      inserted_at: now,
      updated_at: now
    })
  end

  test "no distillation alerts without failures", %{conn: conn} do
    {:ok, view, _} = live_with_sandbox(conn, "/memory")
    refute has_element?(view, "#memory-distill-failed")
    refute has_element?(view, "#memory-distill-blocked")
  end

  test "failed and blocked rows raise alerts", %{conn: conn} do
    seed("failed")
    seed("blocked")
    {:ok, view, _} = live_with_sandbox(conn, "/memory")
    assert has_element?(view, "#memory-distill-failed", "1 个会话提炼失败，见 Sessions 页")
    assert has_element?(view, "#memory-distill-blocked")
  end
end
