defmodule Backplane.Admin.MemoryRecordsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Records
  alias Backplane.Settings

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

    assert {:ok, %{record: %{status: "forgotten", forgotten_reason: "outdated"}}} =
             Records.get(r.id)

    html =
      view |> form("#memory-records-search", %{"include_inactive" => "true"}) |> render_change()

    assert html =~ "Stale fact"
  end

  test "forget with an unknown id flashes not found", %{conn: conn} do
    {:ok, view, _} = live_with_sandbox(conn, "/memory/records")

    html =
      render_submit(view, "forget", %{
        "record_id" => Ecto.UUID.generate(),
        "reason" => "gone"
      })

    assert html =~ "Record not found"
    assert Process.alive?(view.pid)
  end

  test "an invalid filter flashes an error instead of crashing", %{conn: conn} do
    {:ok, view, _} = live_with_sandbox(conn, "/memory/records")

    html = view |> form("#memory-records-search", %{"since" => "not-a-date"}) |> render_change()

    assert html =~ "Invalid filter"
    assert Process.alive?(view.pid)
  end

  describe "overview" do
    test "warns when memory.llm_model is unset and hides the warning when set", %{conn: conn} do
      assert :ok = Settings.set("memory.llm_model", "")

      {:ok, view, html} = live_with_sandbox(conn, "/memory")
      assert html =~ "Distillation is off: memory.llm_model is not configured."
      assert has_element?(view, "#memory-llm-model-warning")

      assert :ok = Settings.set("memory.llm_model", "prov/model")
      {:ok, view, html} = live_with_sandbox(Phoenix.ConnTest.build_conn(), "/memory")
      refute html =~ "Distillation is off"
      refute has_element?(view, "#memory-llm-model-warning")
    end

    test "shows record counts", %{conn: conn} do
      remember(%{
        "kind" => "fact",
        "property" => "p",
        "subjects" => [%{"type" => "a", "key" => "b"}]
      })

      {:ok, _view, html} = live_with_sandbox(conn, "/memory")
      assert html =~ "fact"
    end
  end
end
