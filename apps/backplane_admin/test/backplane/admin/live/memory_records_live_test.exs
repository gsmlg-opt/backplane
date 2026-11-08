defmodule Backplane.Admin.MemoryRecordsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Records

  defp remember(attrs) do
    {:ok, r} = Records.remember(Map.merge(%{"content" => "c", "writer" => "agent"}, attrs))
    r
  end

  test "lists a remembered record with its host", %{conn: conn} do
    r = remember(%{"title" => "Deploy notes", "host_id" => "web-01"})
    {:ok, view, html} = live_with_sandbox(conn, "/memory/records")
    assert html =~ "Deploy notes"
    assert html =~ "web-01"
    assert has_element?(view, "#record-#{r.id}")
  end

  test "search filters records", %{conn: conn} do
    remember(%{"title" => "Alpha thing", "content" => "alpha unique"})
    remember(%{"title" => "Beta thing", "content" => "beta unique"})
    {:ok, view, _} = live_with_sandbox(conn, "/memory/records")

    html = view |> form("#memory-records-search", %{"q" => "alpha"}) |> render_change()
    assert html =~ "Alpha thing"
    refute html =~ "Beta thing"
  end

  test "forget with a reason removes the record from the default list", %{conn: conn} do
    r = remember(%{"title" => "Stale fact"})
    {:ok, view, _} = live_with_sandbox(conn, "/memory/records")

    view |> element("#record-#{r.id}") |> render_click()
    assert has_element?(view, "#memory-record-detail")

    view |> form("#memory-record-forget", %{"reason" => "   "}) |> render_submit()
    assert has_element?(view, "#record-#{r.id}")

    html = view |> form("#memory-record-forget", %{"reason" => "outdated"}) |> render_submit()
    refute html =~ "Stale fact"
    assert {:ok, %{record: %{status: "forgotten", forgotten_reason: "outdated"}}} = Records.get(r.id)

    html = view |> form("#memory-records-search", %{"include_inactive" => "true"}) |> render_change()
    assert html =~ "Stale fact"
  end

  describe "overview" do
    test "warns when memory.llm_model is unset and hides the warning when set", %{conn: conn} do
      :ets.insert(:backplane_settings, {"memory.llm_model", nil})
      on_exit(fn -> :ets.delete(:backplane_settings, "memory.llm_model") end)

      {:ok, view, html} = live_with_sandbox(conn, "/memory")
      assert html =~ "提炼未启用：未配置 memory.llm_model"
      assert has_element?(view, "#memory-llm-model-warning")

      :ets.insert(:backplane_settings, {"memory.llm_model", "prov/model"})
      {:ok, view, html} = live_with_sandbox(Phoenix.ConnTest.build_conn(), "/memory")
      refute html =~ "提炼未启用"
      refute has_element?(view, "#memory-llm-model-warning")
    end

    test "shows record counts", %{conn: conn} do
      remember(%{"kind" => "fact", "property" => "p", "subjects" => [%{"type" => "a", "key" => "b"}]})
      {:ok, _view, html} = live_with_sandbox(conn, "/memory")
      assert html =~ "fact"
    end
  end
end
