defmodule Mix.Tasks.Memory.Activity.VerifyTest do
  use Backplane.Memory.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    on_exit(fn -> Mix.Task.reenable("memory.activity.verify") end)
    :ok
  end

  test "verifies and repairs a bounded partition window" do
    output =
      capture_io(fn ->
        run_task([
          "--client",
          "task-client",
          "--scope",
          "task-scope",
          "--namespace",
          "private",
          "--from",
          "2026-08-01",
          "--to",
          "2026-08-02"
        ])
      end)

    assert output =~ "status=consistent"
    assert output =~ "drift_count=0"

    repaired =
      capture_io(fn ->
        run_task([
          "--client=task-client",
          "--scope=task-scope",
          "--namespace=private",
          "--from=2026-08-01",
          "--to=2026-08-02",
          "--repair"
        ])
      end)

    assert repaired =~ "repaired_subjects=0"
    assert repaired =~ "status=consistent"
  end

  test "requires the complete partition and rejects unknown arguments" do
    for args <- [[], ["--client", "only"], ["--unknown", "value"]] do
      assert_raise Mix.Error, ~r/Usage: mix memory\.activity\.verify/, fn -> run_task(args) end
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("memory.activity.verify")
    Mix.Tasks.Memory.Activity.Verify.run(args)
  end
end
