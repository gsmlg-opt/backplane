defmodule Backplane.Git.Providers.GitLab do
  @moduledoc """
  GitLab API provider implementing the Git.Provider behaviour.
  Uses Req HTTP client to call the GitLab REST API.
  """

  @behaviour Backplane.Git.Provider

  @default_api_url "https://gitlab.com/api/v4"

  @doc """
  Create a new configured Req client for GitLab API calls.
  """
  def client(config) do
    api_url = config[:api_url] || @default_api_url
    token = config[:token]

    headers =
      [{"accept", "application/json"}] ++
        if(token, do: [{"private-token", token}], else: [])

    Req.new(
      base_url: api_url,
      headers: headers
    )
    |> maybe_attach_test_options(config)
  end

  defp maybe_attach_test_options(req, config) do
    case config[:plug] do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp encode_project_id(repo_id) do
    URI.encode_www_form(repo_id)
  end

  @impl true
  def list_repos(opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    query = Keyword.get(opts, :query, "")

    case Req.get(client(config), url: "/projects", params: [search: query]) do
      {:ok, %{status: 200, body: body}} ->
        repos = Enum.map(body, &normalize_repo/1)
        {:ok, repos}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_tree(repo_id, ref, path) do
    fetch_tree(repo_id, ref, path, [])
  end

  def fetch_tree(repo_id, ref, path, opts) do
    config = Keyword.get(opts, :config, %{})
    encoded_id = encode_project_id(repo_id)

    params =
      [ref: ref]
      |> then(fn p -> if path != "" and path != nil, do: Keyword.put(p, :path, path), else: p end)

    case Req.get(client(config), url: "/projects/#{encoded_id}/repository/tree", params: params) do
      {:ok, %{status: 200, body: body}} ->
        entries =
          Enum.map(body, fn item ->
            %{
              name: item["name"],
              path: item["path"],
              type: normalize_gitlab_type(item["type"]),
              size: nil,
              sha: item["id"]
            }
          end)

        {:ok, entries}

      {:ok, %{status: 404, body: body}} ->
        {:error, %{status: 404, message: error_message(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_file(repo_id, path, ref) do
    fetch_file(repo_id, path, ref, [])
  end

  def fetch_file(repo_id, path, ref, opts) do
    config = Keyword.get(opts, :config, %{})
    encoded_id = encode_project_id(repo_id)
    encoded_path = URI.encode_www_form(path)

    case Req.get(client(config),
           url: "/projects/#{encoded_id}/repository/files/#{encoded_path}/raw",
           params: [ref: ref]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, %{status: 404, message: error_message(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_issues(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    encoded_id = encode_project_id(repo_id)
    state = Keyword.get(opts, :state, "opened")

    params = [state: normalize_issue_state_for_api(state)]

    case Req.get(client(config), url: "/projects/#{encoded_id}/issues", params: params) do
      {:ok, %{status: 200, body: body}} ->
        issues = Enum.map(body, &normalize_issue/1)
        {:ok, issues}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_commits(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    encoded_id = encode_project_id(repo_id)

    params =
      []
      |> maybe_add_param(:ref_name, Keyword.get(opts, :sha))
      |> maybe_add_param(:path, Keyword.get(opts, :path))
      |> maybe_add_param(:per_page, Keyword.get(opts, :per_page))

    case Req.get(client(config),
           url: "/projects/#{encoded_id}/repository/commits",
           params: params
         ) do
      {:ok, %{status: 200, body: body}} ->
        commits = Enum.map(body, &normalize_commit/1)
        {:ok, commits}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_merge_requests(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    encoded_id = encode_project_id(repo_id)
    state = Keyword.get(opts, :state, "opened")

    params = [state: normalize_mr_state_for_api(state)]

    case Req.get(client(config),
           url: "/projects/#{encoded_id}/merge_requests",
           params: params
         ) do
      {:ok, %{status: 200, body: body}} ->
        mrs = Enum.map(body, &normalize_merge_request/1)
        {:ok, mrs}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def search_code(query, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    repo = Keyword.get(opts, :repo)

    if repo do
      do_search_code(query, repo, config)
    else
      {:error, "GitLab code search requires a repo parameter"}
    end
  end

  defp do_search_code(query, repo, config) do
    encoded_id = encode_project_id(repo)

    case Req.get(client(config),
           url: "/projects/#{encoded_id}/search",
           params: [scope: "blobs", search: query]
         ) do
      {:ok, %{status: 200, body: body}} ->
        results =
          Enum.map(body, fn item ->
            %{
              name: item["filename"],
              path: item["filename"],
              sha: item["id"],
              url: nil,
              repository: repo
            }
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: error_message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def clone_url(repo_id) do
    "https://gitlab.com/#{repo_id}.git"
  end

  # Normalization helpers

  defp normalize_repo(item) do
    %{
      id: to_string(item["id"]),
      full_name: item["path_with_namespace"],
      description: item["description"],
      url: item["web_url"],
      default_branch: item["default_branch"],
      language: nil,
      stars: item["star_count"],
      updated_at: item["last_activity_at"]
    }
  end

  defp normalize_issue(item) do
    %{
      id: item["id"],
      number: item["iid"],
      title: item["title"],
      state: normalize_gitlab_issue_state(item["state"]),
      author: get_in(item, ["author", "username"]),
      labels: item["labels"] || [],
      created_at: item["created_at"],
      updated_at: item["updated_at"],
      url: item["web_url"]
    }
  end

  defp normalize_commit(item) do
    %{
      sha: item["id"],
      message: item["message"],
      author: item["author_name"],
      date: item["authored_date"],
      url: item["web_url"]
    }
  end

  defp normalize_merge_request(item) do
    %{
      id: item["id"],
      number: item["iid"],
      title: item["title"],
      state: normalize_gitlab_mr_state(item["state"]),
      author: get_in(item, ["author", "username"]),
      source_branch: item["source_branch"],
      target_branch: item["target_branch"],
      created_at: item["created_at"],
      updated_at: item["updated_at"],
      url: item["web_url"]
    }
  end

  defp normalize_gitlab_type("tree"), do: "dir"
  defp normalize_gitlab_type("blob"), do: "file"
  defp normalize_gitlab_type(other), do: other

  # GitLab uses "opened"/"closed" for issues
  defp normalize_gitlab_issue_state("opened"), do: "open"
  defp normalize_gitlab_issue_state(other), do: other

  # GitLab MR states: opened, closed, merged
  defp normalize_gitlab_mr_state("opened"), do: "open"
  defp normalize_gitlab_mr_state("merged"), do: "merged"
  defp normalize_gitlab_mr_state(other), do: other

  # Map incoming state filter to GitLab API format
  defp normalize_issue_state_for_api("open"), do: "opened"
  defp normalize_issue_state_for_api(other), do: other

  defp normalize_mr_state_for_api("open"), do: "opened"
  defp normalize_mr_state_for_api(other), do: other

  defp error_message(body) when is_map(body),
    do: body["message"] || body["error"] || "Unknown error"

  defp error_message(body) when is_binary(body), do: body
  defp error_message(_), do: "Unknown error"

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Keyword.put(params, key, value)
end
