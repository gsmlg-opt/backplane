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
end
