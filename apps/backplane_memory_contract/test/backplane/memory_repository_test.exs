defmodule Backplane.MemoryRepositoryTest do
  use ExUnit.Case, async: true
  alias Backplane.MemoryRepository

  test "standard SSH and HTTPS agree without credentials, preserving repository case" do
    for remote <- [
          "git@GitHub.com:Owner/Repo.git",
          "ssh://git@github.com/Owner/Repo.git",
          "https://secret:token@github.com/Owner/Repo.git?access_token=secret#private"
        ] do
      assert MemoryRepository.normalize_remote(remote) == "github.com/Owner/Repo"
    end
  end

  test "forks, server instances, and nonstandard ports stay distinct and normalized IDs are stable" do
    ids =
      Enum.map(
        [
          "https://git.example/owner/repo",
          "https://git.example/fork/repo",
          "https://other.example/owner/repo",
          "ssh://git@git.example:2222/owner/repo",
          "ssh://git@git.example:443/owner/repo",
          "https://git.example:8443/owner/repo"
        ],
        &MemoryRepository.normalize_remote/1
      )

    assert length(Enum.uniq(ids)) == 6
    assert Enum.all?(ids, &(MemoryRepository.normalize_identifier(&1) == &1))
    assert "git.example:2222/owner/repo" in ids
  end

  test "remote selection prefers origin and refuses ambiguous or unknown local identities" do
    assert MemoryRepository.select_remote(%{
             "origin" => "git@server:owner/repo",
             "upstream" => "git@server:other/repo"
           }) == "server/owner/repo"

    assert MemoryRepository.select_remote(%{"upstream" => "https://server/owner/repo"}) ==
             "server/owner/repo"

    assert MemoryRepository.select_remote(%{"one" => "https://a/repo", "two" => "https://b/repo"}) ==
             nil

    for remote <- [
          nil,
          "",
          "/work/repo",
          "../repo",
          "./repo",
          "relative/repo",
          "repo",
          "file:///work/repo",
          "https://server/a/../repo",
          "C:\\work\\repo"
        ] do
      assert MemoryRepository.normalize_remote(remote) == nil
    end
  end

  test "source associations union paths without inventing an origin or rewriting project" do
    original = %{
      "project" => "/historical/repo",
      "other" => 1,
      "repository_sources" => [
        %{"repository_id" => "https://token@server/org/repo.git", "cwd" => "/first/sub"}
      ]
    }

    metadata =
      MemoryRepository.metadata(original, [
        %{
          "repository_id" => "git@server:org/repo.git",
          "cwd" => "/second",
          "host_id" => "spoofed"
        },
        %{"cwd" => "/non-git"}
      ])

    assert metadata["project"] == "/historical/repo"
    assert metadata["other"] == 1
    assert length(metadata["repository_sources"]) == 3

    assert Enum.count(metadata["repository_sources"], &(&1["repository_id"] == "server/org/repo")) ==
             2

    refute inspect(metadata) =~ "token"
    refute inspect(metadata) =~ "spoofed"
    assert MemoryRepository.metadata(%{"project" => "/old"}) == %{"project" => "/old"}
  end
end
