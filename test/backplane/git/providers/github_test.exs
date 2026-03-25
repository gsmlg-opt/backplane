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
             "stargazers_count" => 23000,
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

    defp route("GET", "/repos/owner/errored/contents/", _query) do
      {500, %{"message" => "Internal Server Error"}}
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
    assert repo.stars == 23000
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
end
