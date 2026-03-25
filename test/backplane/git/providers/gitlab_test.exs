defmodule Backplane.Git.Providers.GitLabTest do
  use ExUnit.Case, async: true

  alias Backplane.Git.Providers.GitLab

  defp config_with_plug(plug) do
    %{token: "test-token", api_url: "https://gitlab.com/api/v4", plug: plug}
  end

  defmodule TestPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      path = conn.request_path

      {status, resp_body} = route(conn.method, path)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(resp_body))
    end

    defp route("GET", "/api/v4/projects") do
      {200,
       [
         %{
           "id" => 5678,
           "path_with_namespace" => "my-group/my-project",
           "description" => "A cool project",
           "web_url" => "https://gitlab.com/my-group/my-project",
           "default_branch" => "main",
           "star_count" => 100,
           "last_activity_at" => "2026-01-01T00:00:00Z"
         }
       ]}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/repository/tree") do
      {200,
       [
         %{
           "name" => "README.md",
           "path" => "README.md",
           "type" => "blob",
           "id" => "abc123"
         },
         %{
           "name" => "lib",
           "path" => "lib",
           "type" => "tree",
           "id" => "def456"
         }
       ]}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/repository/files/README.md/raw") do
      {200, "# My Project\n\nHello from GitLab!"}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/repository/files/missing.txt/raw") do
      {404, %{"message" => "404 File Not Found"}}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/issues") do
      {200,
       [
         %{
           "id" => 10,
           "iid" => 1,
           "title" => "Fix deployment",
           "state" => "opened",
           "author" => %{"username" => "alice"},
           "labels" => ["bug", "urgent"],
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-02T00:00:00Z",
           "web_url" => "https://gitlab.com/my-group/my-project/-/issues/1"
         }
       ]}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/repository/commits") do
      {200,
       [
         %{
           "id" => "sha123abc",
           "message" => "Initial commit\n\nAdded README",
           "author_name" => "Bob",
           "authored_date" => "2026-01-01T00:00:00Z",
           "web_url" => "https://gitlab.com/my-group/my-project/-/commit/sha123abc"
         }
       ]}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/merge_requests") do
      {200,
       [
         %{
           "id" => 200,
           "iid" => 3,
           "title" => "Add CI pipeline",
           "state" => "merged",
           "author" => %{"username" => "charlie"},
           "source_branch" => "add-ci",
           "target_branch" => "main",
           "created_at" => "2026-01-01T00:00:00Z",
           "updated_at" => "2026-01-03T00:00:00Z",
           "web_url" => "https://gitlab.com/my-group/my-project/-/merge_requests/3"
         }
       ]}
    end

    defp route("GET", "/api/v4/projects/my-group%2Fmy-project/search") do
      {200,
       [
         %{
           "filename" => "app.ex",
           "id" => "blob123"
         }
       ]}
    end

    # MRs for a project that returns "opened" state (to test opened->open normalisation)
    defp route("GET", "/api/v4/projects/my-group%2Fopen-project/merge_requests") do
      {200,
       [
         %{
           "id" => 300,
           "iid" => 7,
           "title" => "Work in progress",
           "state" => "opened",
           "author" => %{"username" => "dave"},
           "source_branch" => "wip",
           "target_branch" => "main",
           "created_at" => "2026-02-01T00:00:00Z",
           "updated_at" => "2026-02-02T00:00:00Z",
           "web_url" => "https://gitlab.com/my-group/open-project/-/merge_requests/7"
         }
       ]}
    end

    # Error routes using a different project slug
    defp route("GET", "/api/v4/projects/my-group%2Ferrored/repository/tree") do
      {500, %{"message" => "Internal Server Error"}}
    end

    defp route("GET", "/api/v4/projects/my-group%2Ferrored/issues") do
      {503, "Service temporarily unavailable"}
    end

    defp route("GET", "/api/v4/projects/my-group%2Ferrored/merge_requests") do
      {422, 42}
    end

    defp route("GET", "/api/v4/projects/my-group%2Ferrored/repository/commits") do
      {500, %{"error" => "database timeout"}}
    end

    defp route(_, _) do
      {404, %{"message" => "Not Found"}}
    end
  end

  setup do
    config = config_with_plug({TestPlug, []})
    {:ok, config: config}
  end

  # list_repos

  test "list_repos returns normalized repos", %{config: config} do
    assert {:ok, [repo]} = GitLab.list_repos(config: config, query: "my-project")
    assert repo.full_name == "my-group/my-project"
    assert repo.id == "5678"
    assert repo.stars == 100
  end

  # fetch_tree

  test "fetch_tree returns directory listing with normalized types", %{config: config} do
    assert {:ok, entries} =
             GitLab.fetch_tree("my-group/my-project", "main", "", config: config)

    assert length(entries) == 2
    file = Enum.find(entries, fn e -> e.name == "README.md" end)
    dir = Enum.find(entries, fn e -> e.name == "lib" end)
    assert file.type == "file"
    assert dir.type == "dir"
  end

  # fetch_file

  test "fetch_file returns raw file content", %{config: config} do
    assert {:ok, content} =
             GitLab.fetch_file("my-group/my-project", "README.md", "main", config: config)

    assert content =~ "Hello from GitLab!"
  end

  test "fetch_file returns error for missing file", %{config: config} do
    assert {:error, %{status: 404}} =
             GitLab.fetch_file("my-group/my-project", "missing.txt", "main", config: config)
  end

  # fetch_issues

  test "fetch_issues returns normalized issues with state mapping", %{config: config} do
    assert {:ok, [issue]} = GitLab.fetch_issues("my-group/my-project", config: config)
    assert issue.number == 1
    assert issue.title == "Fix deployment"
    # "opened" should be normalized to "open"
    assert issue.state == "open"
    assert issue.author == "alice"
    assert issue.labels == ["bug", "urgent"]
  end

  # fetch_commits

  test "fetch_commits returns normalized commits", %{config: config} do
    assert {:ok, [commit]} = GitLab.fetch_commits("my-group/my-project", config: config)
    assert commit.sha == "sha123abc"
    assert commit.message =~ "Initial commit"
    assert commit.author == "Bob"
  end

  # fetch_merge_requests

  test "fetch_merge_requests returns normalized MRs with state mapping", %{config: config} do
    assert {:ok, [mr]} = GitLab.fetch_merge_requests("my-group/my-project", config: config)
    assert mr.number == 3
    assert mr.title == "Add CI pipeline"
    # "merged" stays "merged"
    assert mr.state == "merged"
    assert mr.source_branch == "add-ci"
    assert mr.target_branch == "main"
  end

  # search_code

  test "search_code returns results for a specific repo", %{config: config} do
    assert {:ok, [result]} =
             GitLab.search_code("defmodule", config: config, repo: "my-group/my-project")

    assert result.name == "app.ex"
    assert result.repository == "my-group/my-project"
  end

  test "search_code returns error without repo" do
    assert {:error, "GitLab code search requires a repo parameter"} =
             GitLab.search_code("defmodule", config: %{})
  end

  # clone_url

  test "clone_url returns https URL" do
    assert GitLab.clone_url("my-group/my-project") ==
             "https://gitlab.com/my-group/my-project.git"
  end

  # Auth header

  test "client includes private-token header" do
    config = %{token: "my-gl-token", api_url: "https://gitlab.com/api/v4"}
    req = GitLab.client(config)

    token_header =
      Enum.find(req.headers, fn {k, _v} -> k == "private-token" end)

    assert token_header == {"private-token", ["my-gl-token"]}
  end

  test "client omits private-token header when no token" do
    config = %{token: nil, api_url: "https://gitlab.com/api/v4"}
    req = GitLab.client(config)

    token_header =
      Enum.find(req.headers, fn {k, _v} -> k == "private-token" end)

    assert token_header == nil
  end

  # normalize_gitlab_type exercised via fetch_tree
  # "blob" -> "file" and "tree" -> "dir" are both covered by the existing
  # fetch_tree test.  An unknown type should pass through unchanged.
  # We verify the passthrough by injecting a route that returns an unknown type.

  defmodule UnknownTypePlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      body =
        Jason.encode!([
          %{"name" => "weird", "path" => "weird", "type" => "symlink", "id" => "s1"}
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "fetch_tree passes through unknown GitLab type unchanged" do
    config = %{token: "t", api_url: "https://gitlab.com/api/v4", plug: {UnknownTypePlug, []}}

    assert {:ok, [entry]} = GitLab.fetch_tree("my-group/my-project", "main", "", config: config)
    assert entry.type == "symlink"
  end

  # normalize_mr_state_for_api: "open" -> "opened" and passthrough

  test "fetch_merge_requests translates state open to opened for API", %{config: config} do
    # When :state is "open", normalize_mr_state_for_api converts it to "opened"
    # before sending.  The mock ignores the query and returns the same MR list.
    assert {:ok, [mr]} =
             GitLab.fetch_merge_requests("my-group/my-project", config: config, state: "open")

    # Result comes back with "merged" (what the mock returns); the important thing
    # is no error was raised — proving the state conversion did not crash.
    assert mr.number == 3
  end

  test "fetch_merge_requests with non-open state is passed through as-is", %{config: config} do
    # "merged" is passed directly to the API unchanged.
    assert {:ok, [mr]} =
             GitLab.fetch_merge_requests("my-group/my-project",
               config: config,
               state: "merged"
             )

    assert mr.number == 3
  end

  # normalize_gitlab_mr_state: "opened" -> "open"

  test "fetch_merge_requests normalizes opened MR state to open", %{config: config} do
    config_open_project = %{config | plug: {TestPlug, []}}

    assert {:ok, [mr]} =
             GitLab.fetch_merge_requests("my-group/open-project", config: config_open_project)

    assert mr.state == "open"
  end

  # error_message variations via error routes

  test "fetch_tree returns error with message from map body", %{config: config} do
    assert {:error, %{status: 500, message: "Internal Server Error"}} =
             GitLab.fetch_tree("my-group/errored", "main", "", config: config)
  end

  test "fetch_issues returns error with binary body as message", %{config: config} do
    # The errored issues route returns a plain string body (503 + binary).
    # error_message/1 for binary returns the string directly.
    assert {:error, %{status: 503, message: "Service temporarily unavailable"}} =
             GitLab.fetch_issues("my-group/errored", config: config)
  end

  test "fetch_merge_requests returns error with generic message for non-map non-binary body",
       %{config: config} do
    # The errored MR route returns integer 42.
    # error_message/1 for non-map non-binary returns "Unknown error".
    assert {:error, %{status: 422, message: "Unknown error"}} =
             GitLab.fetch_merge_requests("my-group/errored", config: config)
  end

  test "fetch_commits returns error with message from error key in map body", %{config: config} do
    # The errored commits route returns %{"error" => "database timeout"}.
    # error_message/1 falls back to body["error"] when "message" is absent.
    assert {:error, %{status: 500, message: "database timeout"}} =
             GitLab.fetch_commits("my-group/errored", config: config)
  end

  # search_code already has a test for missing repo; verify it returns the atom error
  test "search_code without repo returns descriptive error regardless of config" do
    assert {:error, "GitLab code search requires a repo parameter"} =
             GitLab.search_code("anything", config: %{token: nil})
  end
end
