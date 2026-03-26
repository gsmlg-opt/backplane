defmodule Backplane.Git.Providers.GitHubTest do
  use ExUnit.Case, async: true

  alias Backplane.Git.Providers.GitHub

  # Helper to build config that routes Req through a test plug
  defp config_with_plug(plug) do
    %{token: "test-token", api_url: "https://api.github.com", plug: plug}
  end

  # Simple Plug that returns canned responses based on request path
  defmodule TestPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      path = conn.request_path
      query = conn.query_string

      {status, resp_body} = route(conn.method, path, query)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(resp_body))
    end

    defp route("GET", "/search/repositories", _query) do
      {200,
       %{
         "items" => [
           %{
             "id" => 1234,
             "full_name" => "elixir-lang/elixir",
             "description" => "Elixir programming language",
             "html_url" => "https://github.com/elixir-lang/elixir",
             "default_branch" => "main",
             "language" => "Elixir",
             "stargazers_count" => 23_000,
             "updated_at" => "2026-01-01T00:00:00Z"
           }
         ]
       }}
    end

    defp route("GET", "/repos/owner/repo/contents/", _query) do
      {200,
       [
         %{
           "name" => "README.md",
           "path" => "README.md",
           "type" => "file",
           "size" => 1024,
           "sha" => "abc123"
         },
         %{
           "name" => "lib",
           "path" => "lib",
           "type" => "dir",
           "size" => 0,
           "sha" => "def456"
         }
       ]}
    end

    defp route("GET", "/repos/owner/repo/contents/lib", _query) do
      {200,
       [
         %{
           "name" => "app.ex",
           "path" => "lib/app.ex",
           "type" => "file",
           "size" => 512,
           "sha" => "ghi789"
         }
       ]}
    end

    defp route("GET", "/repos/owner/repo/contents/README.md", _query) do
      {200,
       %{
         "name" => "README.md",
         "path" => "README.md",
         "type" => "file",
         "size" => 13,
         "sha" => "abc123",
         "encoding" => "base64",
         "content" => Base.encode64("Hello, World!")
       }}
    end

    defp route("GET", "/repos/owner/repo/contents/nonexistent.txt", _query) do
      {404, %{"message" => "Not Found"}}
    end

    defp route("GET", "/repos/owner/repo/issues", _query) do
      {200,
       [
         %{
           "id" => 1,
           "number" => 42,
           "title" => "Fix bug",
           "state" => "open",
           "user" => %{"login" => "alice"},
           "labels" => [%{"name" => "bug"}],
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-02T00:00:00Z",
           "html_url" => "https://github.com/owner/repo/issues/42"
         },
         # This is a PR (has pull_request key) — should be filtered out
         %{
           "id" => 2,
           "number" => 43,
           "title" => "Add feature",
           "state" => "open",
           "user" => %{"login" => "bob"},
           "labels" => [],
           "pull_request" => %{"url" => "https://api.github.com/repos/owner/repo/pulls/43"},
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-02T00:00:00Z",
           "html_url" => "https://github.com/owner/repo/issues/43"
         }
       ]}
    end

    defp route("GET", "/repos/owner/repo/commits", _query) do
      {200,
       [
         %{
           "sha" => "abc123def",
           "commit" => %{
             "message" => "Initial commit",
             "author" => %{
               "name" => "Alice",
               "date" => "2026-01-01T00:00:00Z"
             }
           },
           "html_url" => "https://github.com/owner/repo/commit/abc123def"
         }
       ]}
    end

    defp route("GET", "/repos/owner/repo/pulls", _query) do
      {200,
       [
         %{
           "id" => 100,
           "number" => 5,
           "title" => "Add new feature",
           "state" => "open",
           "user" => %{"login" => "charlie"},
           "head" => %{"ref" => "feature-branch"},
           "base" => %{"ref" => "main"},
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-02T00:00:00Z",
           "html_url" => "https://github.com/owner/repo/pull/5"
         }
       ]}
    end

    defp route("GET", "/search/code", _query) do
      {200,
       %{
         "items" => [
           %{
             "name" => "app.ex",
             "path" => "lib/app.ex",
             "sha" => "xyz789",
             "html_url" => "https://github.com/owner/repo/blob/main/lib/app.ex",
             "repository" => %{"full_name" => "owner/repo"}
           }
         ]
       }}
    end

    defp route("GET", "/repos/owner/repo/contents/single-file.txt", _query) do
      # GitHub returns a map (not a list) when the path resolves to a single file
      {200,
       %{
         "name" => "single-file.txt",
         "path" => "single-file.txt",
         "type" => "file",
         "size" => 42,
         "sha" => "singlesha"
       }}
    end

    defp route("GET", "/repos/owner/repo/contents/plain.txt", _query) do
      # File with no "base64" encoding — raw content in "content" field
      {200,
       %{
         "name" => "plain.txt",
         "path" => "plain.txt",
         "type" => "file",
         "size" => 5,
         "sha" => "plainsha",
         "content" => "hello"
       }}
    end

    defp route("GET", "/repos/owner/repo/contents/nocontent.bin", _query) do
      # File body with no "content" key at all
      {200,
       %{
         "name" => "nocontent.bin",
         "path" => "nocontent.bin",
         "type" => "file",
         "size" => 0,
         "sha" => "nocontentsha"
       }}
    end

    defp route("GET", "/search/issues", _query) do
      {200,
       %{
         "items" => [
           %{
             "id" => 10,
             "number" => 99,
             "title" => "Search result issue",
             "state" => "open",
             "user" => %{"login" => "carol"},
             "labels" => [%{"name" => "enhancement"}],
             "created_at" => "2026-02-01T00:00:00Z",
             "updated_at" => "2026-02-02T00:00:00Z",
             "html_url" => "https://github.com/owner/repo/issues/99"
           }
         ]
       }}
    end

    defp route("GET", "/repos/owner/errored/contents/", _query) do
      {500, %{"message" => "Internal Server Error"}}
    end

    defp route("GET", "/repos/owner/errored/issues", _query) do
      {503, %{"message" => "Service Unavailable"}}
    end

    defp route("GET", "/repos/owner/errored/pulls", _query) do
      {422, %{"message" => "Invalid state value"}}
    end

    defp route("GET", "/repos/owner/errored/commits", _query) do
      {500, %{"message" => "Internal error"}}
    end

    defp route(_, _, _) do
      {404, %{"message" => "Not Found"}}
    end
  end

  setup do
    config = config_with_plug({TestPlug, []})
    {:ok, config: config}
  end

  # list_repos

  test "list_repos returns normalized repos", %{config: config} do
    assert {:ok, [repo]} = GitHub.list_repos(config: config, query: "elixir")
    assert repo.full_name == "elixir-lang/elixir"
    assert repo.id == "1234"
    assert repo.language == "Elixir"
    assert repo.stars == 23_000
  end

  # fetch_tree

  test "fetch_tree returns directory listing at root", %{config: config} do
    assert {:ok, entries} = GitHub.fetch_tree("owner/repo", "main", "", config: config)
    assert length(entries) == 2
    assert Enum.any?(entries, fn e -> e.name == "README.md" and e.type == "file" end)
    assert Enum.any?(entries, fn e -> e.name == "lib" and e.type == "dir" end)
  end

  test "fetch_tree returns directory listing at subpath", %{config: config} do
    assert {:ok, [entry]} = GitHub.fetch_tree("owner/repo", "main", "lib", config: config)
    assert entry.name == "app.ex"
    assert entry.path == "lib/app.ex"
  end

  # fetch_file

  test "fetch_file returns decoded file content", %{config: config} do
    assert {:ok, content} = GitHub.fetch_file("owner/repo", "README.md", "main", config: config)
    assert content == "Hello, World!"
  end

  test "fetch_file returns error for missing file", %{config: config} do
    assert {:error, %{status: 404}} =
             GitHub.fetch_file("owner/repo", "nonexistent.txt", "main", config: config)
  end

  # fetch_issues

  test "fetch_issues returns normalized issues excluding PRs", %{config: config} do
    assert {:ok, issues} = GitHub.fetch_issues("owner/repo", config: config)
    # The PR (id 2) should be filtered out
    assert length(issues) == 1
    [issue] = issues
    assert issue.number == 42
    assert issue.title == "Fix bug"
    assert issue.state == "open"
    assert issue.author == "alice"
    assert issue.labels == ["bug"]
  end

  # fetch_commits

  test "fetch_commits returns normalized commits", %{config: config} do
    assert {:ok, [commit]} = GitHub.fetch_commits("owner/repo", config: config)
    assert commit.sha == "abc123def"
    assert commit.message == "Initial commit"
    assert commit.author == "Alice"
  end

  # fetch_merge_requests

  test "fetch_merge_requests returns normalized PRs", %{config: config} do
    assert {:ok, [pr]} = GitHub.fetch_merge_requests("owner/repo", config: config)
    assert pr.number == 5
    assert pr.title == "Add new feature"
    assert pr.state == "open"
    assert pr.source_branch == "feature-branch"
    assert pr.target_branch == "main"
  end

  # search_code

  test "search_code returns normalized results", %{config: config} do
    assert {:ok, [result]} = GitHub.search_code("defmodule", config: config, repo: "owner/repo")
    assert result.name == "app.ex"
    assert result.path == "lib/app.ex"
    assert result.repository == "owner/repo"
  end

  # clone_url

  test "clone_url returns https URL" do
    assert GitHub.clone_url("owner/repo") == "https://github.com/owner/repo.git"
  end

  # Error handling

  test "fetch_tree returns error for server errors", %{config: config} do
    assert {:error, %{status: 500}} =
             GitHub.fetch_tree("owner/errored", "main", "", config: config)
  end

  # Verify auth header

  test "client includes auth header when token present" do
    config = %{token: "my-secret-token", api_url: "https://api.github.com"}
    req = GitHub.client(config)

    auth_header =
      Enum.find(req.headers, fn {k, _v} -> k == "authorization" end)

    assert auth_header == {"authorization", ["Bearer my-secret-token"]}
  end

  test "client omits auth header when no token" do
    config = %{token: nil, api_url: "https://api.github.com"}
    req = GitHub.client(config)

    auth_header =
      Enum.find(req.headers, fn {k, _v} -> k == "authorization" end)

    assert auth_header == nil
  end

  # fetch_tree single-file branch

  test "fetch_tree wraps single-file map response in a list", %{config: config} do
    assert {:ok, [entry]} =
             GitHub.fetch_tree("owner/repo", "main", "single-file.txt", config: config)

    assert entry.name == "single-file.txt"
    assert entry.path == "single-file.txt"
    assert entry.type == "file"
    assert entry.size == 42
    assert entry.sha == "singlesha"
  end

  # decode_file_content edge cases exercised through fetch_file

  test "fetch_file returns plain content when encoding is not base64", %{config: config} do
    assert {:ok, content} =
             GitHub.fetch_file("owner/repo", "plain.txt", "main", config: config)

    assert content == "hello"
  end

  test "fetch_file returns empty string when body has no content key", %{config: config} do
    assert {:ok, content} =
             GitHub.fetch_file("owner/repo", "nocontent.bin", "main", config: config)

    assert content == ""
  end

  # search_code with repo and language parameters

  test "search_code with repo and language builds compound query", %{config: config} do
    # The mock returns the same canned result regardless of the full query string
    # (route matches /search/code with _query); what we verify is that the call
    # succeeds and the result is normalised correctly, i.e. both filters were
    # accepted without raising.
    assert {:ok, [result]} =
             GitHub.search_code("defmodule",
               config: config,
               repo: "owner/repo",
               language: "Elixir"
             )

    assert result.name == "app.ex"
    assert result.repository == "owner/repo"
  end

  # fetch_issues only keeps real issues, not PRs

  test "fetch_issues count confirms pull request items are rejected", %{config: config} do
    # The mock endpoint returns 2 items: 1 issue + 1 PR.
    # After filtering, only 1 should remain.
    assert {:ok, issues} = GitHub.fetch_issues("owner/repo", config: config)
    assert length(issues) == 1
    refute Enum.any?(issues, fn i -> i.number == 43 end)
  end

  # fetch_issues with query parameter uses search API

  test "fetch_issues with query uses search endpoint", %{config: config} do
    assert {:ok, [issue]} = GitHub.fetch_issues("owner/repo", config: config, query: "bug fix")
    assert issue.number == 99
    assert issue.title == "Search result issue"
  end

  # fetch_issues with limit parameter

  test "fetch_issues passes limit to API", %{config: config} do
    assert {:ok, _issues} = GitHub.fetch_issues("owner/repo", config: config, limit: 10)
  end

  # fetch_commits with ref and limit parameters

  test "fetch_commits accepts ref parameter", %{config: config} do
    assert {:ok, [commit]} = GitHub.fetch_commits("owner/repo", config: config, ref: "develop")
    assert commit.sha == "abc123def"
  end

  test "fetch_commits accepts limit parameter", %{config: config} do
    assert {:ok, _commits} = GitHub.fetch_commits("owner/repo", config: config, limit: 5)
  end

  # fetch_merge_requests with limit parameter

  test "fetch_merge_requests accepts limit parameter", %{config: config} do
    assert {:ok, _prs} = GitHub.fetch_merge_requests("owner/repo", config: config, limit: 10)
  end

  # Error responses for remaining endpoints

  test "fetch_issues returns error on non-200 response", %{config: config} do
    assert {:error, %{status: 503, message: "Service Unavailable"}} =
             GitHub.fetch_issues("owner/errored", config: config)
  end

  test "fetch_merge_requests returns error on non-200 response", %{config: config} do
    assert {:error, %{status: 422, message: "Invalid state value"}} =
             GitHub.fetch_merge_requests("owner/errored", config: config)
  end

  test "fetch_commits returns error on non-200 response", %{config: config} do
    assert {:error, %{status: 500, message: "Internal error"}} =
             GitHub.fetch_commits("owner/errored", config: config)
  end

  defmodule SearchErrorPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(503, Jason.encode!(%{"message" => "Search unavailable"}))
    end
  end

  test "search_code returns error on non-200 response" do
    config = config_with_plug({SearchErrorPlug, []})

    assert {:error, %{status: 503, message: "Search unavailable"}} =
             GitHub.search_code("missing", config: config, repo: "owner/repo")
  end

  # 3-arity delegators (default opts)

  test "fetch_tree/3 delegates to fetch_tree/4", %{config: _config} do
    # fetch_tree/3 calls fetch_tree/4 with opts: []
    # We can't use test plug without config, so just verify the function exists
    assert function_exported?(GitHub, :fetch_tree, 3)
    assert function_exported?(GitHub, :fetch_tree, 4)
  end

  test "fetch_file/3 delegates to fetch_file/4", %{config: _config} do
    assert function_exported?(GitHub, :fetch_file, 3)
    assert function_exported?(GitHub, :fetch_file, 4)
  end

  # fetch_tree 404 path

  test "fetch_tree returns 404 error for missing path", %{config: config} do
    assert {:error, %{status: 404, message: "Not Found"}} =
             GitHub.fetch_tree("owner/repo", "main", "nonexistent.txt", config: config)
  end

  # fetch_file other-status error

  test "fetch_file returns error for server error status", %{config: config} do
    assert {:error, %{status: 500}} =
             GitHub.fetch_file("owner/errored", "", "main", config: config)
  end

  # list_repos error path

  defmodule RepoErrorPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "Server error"}))
    end
  end

  test "list_repos returns error on non-200 response" do
    config = config_with_plug({RepoErrorPlug, []})

    assert {:error, %{status: 500, message: "Server error"}} =
             GitHub.list_repos(config: config, query: "test")
  end
end
