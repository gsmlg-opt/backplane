defmodule Mix.Tasks.Memory.EvalTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "writes a CI smoke evaluation report", %{tmp_dir: tmp_dir} do
    report_path = Path.join(tmp_dir, "memory-v2-eval-ci-smoke.json")

    Mix.Task.reenable("memory.eval")
    Mix.Tasks.Memory.Eval.run(["--profile", "ci", "--report", report_path])

    assert {:ok, report} = report_path |> File.read!() |> Jason.decode()
    assert report["profile"] == "ci"
    assert report["performance_authoritative"] == false
    assert report["effective_thresholds"]["retrieval_fusion_p95_ms_max_exclusive"] == 3_000.0
    assert report["effective_thresholds"]["e2e_p95_ms_max_exclusive"] == 8_000.0
    assert report["passed"]
  end

  test "rejects an invalid evaluation profile" do
    Mix.Task.reenable("memory.eval")

    assert_raise Mix.Error,
                 "usage: mix memory.eval --profile performance|ci [--report PATH] [--longmemeval PATH] [--sidecar PATH]",
                 fn ->
                   Mix.Tasks.Memory.Eval.run(["--profile", "invalid"])
                 end
  end
end
