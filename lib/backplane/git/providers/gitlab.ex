defmodule Backplane.Git.Providers.GitLab do
  @moduledoc """
  GitLab API provider implementing the Git.Provider behaviour.
  Uses Req HTTP client to call the GitLab REST API.
  """

  @behaviour Backplane.Git.Provider

  alias Backplane.Git.RateLimitCache
  alias Backplane.Utils

  @default_api_url "https://gitlab.com/api/v4"

  @doc """
  Create a new configured Req client for GitLab API calls.
  """
  @spec client(map()) :: Req.Request.t()
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
      plug -> Req.merge(req, plug: plug, retry: false)
    end
  end

  defp encode_project_id(repo_id) do
    URI.encode_www_form(repo_id)
  end

  @impl true
  def list_repos(opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    query = Keyword.get(opts, :query, "")

    case get_with_rate_limit(config, url: "/projects", params: [search: query]) do
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

    case get_with_rate_limit(config,
           url: "/projects/#{encoded_id}/repository/tree",
           params: params
         ) do
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

    case get_with_rate_limit(config,
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

    params =
      [state: normalize_issue_state_for_api(state)]
      |> maybe_add_param(:search, Keyword.get(opts, :query))
      |> maybe_add_param(:per_page, Keyword.get(opts, :limit))

    case get_with_rate_limit(config, url: "/projects/#{encoded_id}/issues", params: params) do
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
      |> maybe_add_param(:ref_name, Keyword.get(opts, :ref))
      |> maybe_add_param(:path, Keyword.get(opts, :path))
      |> maybe_add_param(:per_page, Keyword.get(opts, :limit))

    case get_with_rate_limit(config,
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

    params =
      [state: normalize_mr_state_for_api(state)]
      |> maybe_add_param(:per_page, Keyword.get(opts, :limit))

    case get_with_rate_limit(config,
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

    case get_with_rate_limit(config,
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
      body_preview: truncate_body(item["description"]),
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

  @body_preview_length 200

  defp truncate_body(nil), do: nil
  defp truncate_body(""), do: nil

  defp truncate_body(body) when byte_size(body) > @body_preview_length do
    String.slice(body, 0, @body_preview_length) <> "..."
  end

  defp truncate_body(body), do: body

  defp error_message(body) when is_map(body),
    do: body["message"] || body["error"] || "Unknown error"

  defp error_message(body) when is_binary(body), do: body
  defp error_message(_), do: "Unknown error"

  defp maybe_add_param(params, key, value), do: Utils.maybe_put(params, key, value)

  @doc false
  def get_with_rate_limit(config, opts) do
    key = provider_key(config)

    if RateLimitCache.rate_limited?(key) do
      info = RateLimitCache.get(key)
      reset_in = (info[:reset] || 0) - System.system_time(:second)
      {:error, %{status: 429, message: "Rate limited. Resets in #{max(reset_in, 0)}s."}}
    else
      result = Req.get(client(config), opts)
      cache_rate_limit(config, result)
      result
    end
  end

  defp cache_rate_limit(config, {:ok, %{headers: headers}}) do
    remaining = get_header(headers, "ratelimit-remaining")
    limit = get_header(headers, "ratelimit-limit")
    reset = get_header(headers, "ratelimit-reset")

    if remaining do
      key = provider_key(config)

      RateLimitCache.put(key, %{
        remaining: parse_int(remaining),
        limit: parse_int(limit),
        reset: parse_int(reset)
      })
    end
  end

  defp cache_rate_limit(_config, _error), do: :ok

  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [v | _] -> v
      v -> v
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp provider_key(config) do
    api_url = config[:api_url] || @default_api_url

    if api_url == @default_api_url do
      "gitlab"
    else
      "gitlab.#{URI.parse(api_url).host}"
    end
  end
end
