defmodule Backplane.Memory.QueryLogPrivacyTest do
  use Backplane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.Repo
  alias Backplane.Memory.QueryLogFilter

  test "memory SQL debug logs redact bind values without hiding unrelated query parameters" do
    :ok = QueryLogFilter.install()
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    memory_markers = [
      "memory-content-#{System.unique_integer([:positive])}",
      "memory-prompt-#{System.unique_integer([:positive])}",
      "memory-tool-#{System.unique_integer([:positive])}",
      "memory-raw-payload-#{System.unique_integer([:positive])}"
    ]

    unrelated_marker = "ordinary-repo-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        assert %{num_rows: 0} =
                 Repo.query!(
                   "SELECT $1::text, $2::text, $3::text, $4::text FROM bpm_memories LIMIT 0",
                   memory_markers
                 )

        assert %{rows: [[^unrelated_marker]]} =
                 Repo.query!("SELECT $1::text", [unrelated_marker])
      end)

    for marker <- memory_markers do
      refute log =~ marker
    end

    assert log =~ "MEMORY QUERY"
    assert log =~ unrelated_marker
  end
end
