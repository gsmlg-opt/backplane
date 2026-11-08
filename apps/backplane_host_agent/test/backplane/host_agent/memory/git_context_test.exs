defmodule Backplane.HostAgent.Memory.GitContextTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.GitContext
  alias Backplane.HostAgent.Memory.Hooks.Codex

  test "non-Git, missing Git, failed discovery and missing remote retain paths without rejecting writes" do
    for runner <- [
          fn _, _ -> {"not a git repository", 128} end,
          fn _, _ -> raise ErlangError, original: :enoent end
        ] do
      assert [%{"repository_id" => nil, "checkout_root" => nil, "cwd" => "/work/no-git"}] =
               GitContext.discover("/work/no-git", runner: runner)
    end

    runner = fn _, args ->
      if args == ["rev-parse", "--show-toplevel"], do: {"/work/repo\n", 0}, else: {"", 0}
    end

    assert [%{"repository_id" => nil, "checkout_root" => "/work/repo"}] =
             GitContext.discover("/work/repo/sub", runner: runner)

    assert GitContext.enrich_arguments(%{
             "content" => "valid",
             "metadata" => %{"project" => "/missing/path"}
           })["content"] == "valid"

    assert GitContext.enrich_arguments(%{"content" => "valid"}) == %{
             "content" => "valid",
             "metadata" => %{}
           }
  end

  test "capture retains trusted host and historical project while adding honest source metadata" do
    source = %{
      "session_id" => "s",
      "source_event_id" => "one",
      "cwd" => "/missing/path",
      "host_id" => "spoofed"
    }

    assert {:ok, event} =
             Codex.normalize("SessionStart", source, %{host_id: "authenticated-host"})

    assert event.host_id == "authenticated-host"
    assert event.project == "/missing/path"
    refute Map.has_key?(event.payload["source"], "host_id")

    assert [%{"repository_id" => nil, "cwd" => "/missing/path"}] =
             event.payload["repository_sources"]
  end
end
