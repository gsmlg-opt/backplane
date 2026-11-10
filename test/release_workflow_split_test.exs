ExUnit.start()

defmodule Backplane.ReleaseWorkflowSplitTest do
  use ExUnit.Case, async: true

  test "the public release waits for Hex and Docker but never host-agent builds" do
    jobs = YamlElixir.read_from_file!(".github/workflows/release.yml")["jobs"]

    assert Enum.map(jobs["build"]["strategy"]["matrix"]["include"], & &1["release"]) ==
             ["backplane", "backplane"]

    assert jobs["publish"]["name"] == "Stage draft GitHub Release"
    assert "hex-preflight" in jobs["publish"]["needs"]
    assert "docker-build" in jobs["publish"]["needs"]
    assert "docker-image" in jobs["finalize"]["needs"]
    assert "hex-packages" in jobs["finalize"]["needs"]
    assert jobs["dispatch-host-agent"]["needs"] == "finalize"
    assert jobs["dispatch-host-agent"]["permissions"]["actions"] == "write"

    refute Enum.any?(jobs, fn {_key, job} ->
             "dispatch-host-agent" in List.wrap(job["needs"])
           end)
  end

  test "plugin qualification has its own workflow and is absent from release and host builds" do
    for path <- [".github/workflows/release.yml", ".github/workflows/host-agent-release.yml"] do
      workflow = File.read!(path)
      refute workflow =~ "openclaw"
      refute workflow =~ "OpenClaw"
      refute workflow =~ "Hermes"
      refute workflow =~ "hermes"
    end

    plugin = YamlElixir.read_from_file!(".github/workflows/memory-plugins.yml")
    assert Map.has_key?(plugin["on"], "workflow_dispatch")
    steps = plugin["jobs"]["memory-plugins"]["steps"]
    names = Enum.map(steps, & &1["name"])

    for name <- [
          "Verify OpenClaw acceptance helpers",
          "Verify OpenClaw provider contract",
          "Verify packaged Hermes provider",
          "Verify packaged OpenClaw provider",
          "Verify packaged client plugins and hook client"
        ] do
      assert name in names
    end

    refute "Verify real OpenClaw canonical path" in names
  end

  test "publication workflows never execute tests or Memory evaluations" do
    for path <- [".github/workflows/release.yml", ".github/workflows/host-agent-release.yml"] do
      jobs = YamlElixir.read_from_file!(path)["jobs"]

      for {_name, job} <- jobs, step <- job["steps"] || [], run = step["run"], is_binary(run) do
        refute run =~ ~r/\bmix\s+test\b|\belixir\s+test\/|\bnode\s+--test|\bpython\S*.*unittest/
        refute run =~ ~r/mix memory\.(eval|qualify|seed_bench|replay)/
      end
    end
  end

  test "release preparation only installs dependencies and compiles without consulting CI" do
    workflow = File.read!(".github/workflows/release.yml")
    steps = YamlElixir.read_from_string!(workflow)["jobs"]["prepare"]["steps"]

    assert Enum.any?(steps, &(&1["run"] == "mix deps.get"))
    assert Enum.any?(steps, &(&1["run"] == "mix compile"))
    refute workflow =~ "check_release_source.py"
    refute workflow =~ "actions/runs"
    refute workflow =~ "workflow_run"
  end

  test "Docker image staging includes its dedicated hidden artifact directory" do
    job = YamlElixir.read_from_file!(".github/workflows/docker-image.yml")["jobs"]["docker-image"]
    upload = Enum.find(job["steps"], &(&1["uses"] == "actions/upload-artifact@v7"))
    assert upload["with"]["path"] == "${{ github.workspace }}/.docker-image/"
    assert upload["with"]["include-hidden-files"] == true
  end

  test "the version commit is prepared before qualification and all builds use that revision" do
    jobs = YamlElixir.read_from_file!(".github/workflows/release.yml")["jobs"]
    assert jobs["build"]["needs"] == ["prepare", "web-assets"]
    assert jobs["prepare"]["outputs"]["gated_sha"] == "${{ steps.version.outputs.sha }}"
    refute Enum.any?(jobs["publish"]["steps"], &((&1["run"] || "") =~ "git push"))
    assert jobs["docker-build"]["with"]["publish"] == false
    assert jobs["docker-image"]["with"]["source_run_id"] == "${{ github.run_id }}"
  end

  test "host-agent retries target the original release revision and cannot update Latest" do
    workflow = YamlElixir.read_from_file!(".github/workflows/host-agent-release.yml")
    assert workflow["on"]["workflow_dispatch"]["inputs"]["revision"]["required"]
    assert workflow["concurrency"]["cancel-in-progress"] == false
    targets = workflow["jobs"]["build"]["strategy"]["matrix"]["target"]
    assert length(targets) == 4
    steps = workflow["jobs"]["build"]["steps"]

    assert Enum.find(steps, &(&1["uses"] == "actions/checkout@v7"))["with"]["ref"] ==
             "${{ inputs.revision }}"

    refute File.read!(".github/workflows/host-agent-release.yml") =~ "--latest"
  end
end
