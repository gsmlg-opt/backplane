defmodule Backplane.Admin.LogsLiveTest do
  use Backplane.Admin.LiveCase

  import Ecto.Query

  alias Backplane.Memory.Workers.GraphExtractWorker
  alias Backplane.Repo

  test "renders logs page with tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/system/logs")

    assert html =~ "Logs"
    assert html =~ "Background Jobs"
    assert html =~ "Tool Calls"
  end

  test "can switch between tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/logs")

    html = view |> element("el-dm-button", "Tool Calls") |> render_click()
    assert html =~ "Events appear in real-time"
  end

  test "loads an exact failed job and renders only a sanitized bounded error", %{conn: conn} do
    job =
      GraphExtractWorker.new(%{"memory_id" => Ecto.UUID.generate()})
      |> Repo.insert!()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [
        state: "discarded",
        attempted_at: DateTime.utc_now(),
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(DateTime.utc_now()),
            "error" => "upload failed token=super-secret"
          }
        ]
      ]
    )

    {:ok, view, html} = live(conn, "/system/logs?job_id=#{job.id}")

    assert has_element?(view, "#job-detail-#{job.id}", "GraphExtractWorker")
    assert html =~ "upload failed"
    assert html =~ "[REDACTED]"
    refute html =~ "super-secret"
  end
end
