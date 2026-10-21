defmodule Backplane.HostAgent.Memory.GitContextTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.GitContext
  alias Backplane.HostAgent.Memory.Hooks.Codex

  test "subdirectories and worktrees share remote identity while retaining distinct checkout paths" do
    root =
      Path.join(System.tmp_dir!(), "backplane-provenance-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(Path.join(repo, "sub"))
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repo, ["init", "--quiet"])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "fixture"
    ])

    git!(repo, ["remote", "add", "origin", "https://user:secret@git.example/org/repo.git"])
    git!(repo, ["worktree", "add", "--quiet", "-b", "test-worktree", worktree])

    assert [first] = GitContext.discover(Path.join(repo, "sub"))
    assert [second] = GitContext.discover(worktree)
    assert first["repository_id"] == "git.example/org/repo"
    assert second["repository_id"] == first["repository_id"]
    assert File.stat!(first["checkout_root"]).inode == File.stat!(repo).inode
    assert File.stat!(second["checkout_root"]).inode == File.stat!(worktree).inode
    assert first["checkout_root"] != second["checkout_root"]
    assert first["cwd"] == Path.join(repo, "sub")
    refute inspect([first, second]) =~ "secret"

    store =
      start_supervised!(
        {Backplane.HostAgent.Memory.Store, database: Path.join(root, "memory.db"), pool_size: 1}
      )

    assert :ok = Backplane.HostAgent.Memory.Migrator.migrate(store)

    args = %{
      "content" => "explicit repository memory",
      "metadata" => %{"cwd" => Path.join(repo, "sub"), "project" => repo},
      "idempotency_key" => "explicit"
    }

    opts = [store: store, config: %{bound_scope: "proj_local"}, agent_id: "test"]
    assert {:ok, %{"id" => memory_id}} = Backplane.HostAgent.Memory.remember(args, opts)

    assert {:ok, %{"id" => ^memory_id, "dedup" => true}} =
             Backplane.HostAgent.Memory.remember(args, opts)

    assert {:ok, %{rows: [row]}} =
             Backplane.HostAgent.Memory.Store.query(
               store,
               "SELECT metadata FROM memories WHERE id = ?",
               [memory_id]
             )

    metadata = Jason.decode!(row["metadata"])
    assert metadata["repository_sources"] == [first]
    assert metadata["project"] == repo

    assert {:ok, %{rows: [outbox]}} =
             Backplane.HostAgent.Memory.Store.query(
               store,
               "SELECT payload FROM memory_outbox WHERE memory_id = ?",
               [memory_id]
             )

    assert Jason.decode!(outbox["payload"])["metadata"]["repository_sources"] == [first]
  end

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

  defp git!(cwd, args) do
    assert {_output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
  end
end
