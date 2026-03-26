defmodule Backplane.Git.Providers.GitHub do
  @moduledoc """
  GitHub API provider implementing the Git.Provider behaviour.
  Uses Req HTTP client to call the GitHub REST API.
  """

  @behaviour Backplane.Git.Provider

  @default_api_url "https://api.github.com"

  @doc """
  Create a new configured Req client for GitHub API calls.
  """
  def client(config) do
    api_url = config[:api_url] || @default_api_url
    token = config[:token]

    headers =
      [{"accept", "application/vnd.github+json"}] ++
        if(token, do: [{"authorization", "Bearer #{token}"}], else: [])

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

  @impl true
  def list_repos(opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    query = Keyword.get(opts, :query, "")

    case Req.get(client(config), url: "/search/repositories", params: [q: query]) do
      {:ok, %{status: 200, body: body}} ->
        repos =
          (body["items"] || [])
          |> Enum.map(&normalize_repo/1)

        {:ok, repos}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

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
    url_path = "/repos/#{repo_id}/contents/#{path}"

    case Req.get(client(config), url: url_path, params: [ref: ref]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        entries =
          body
          |> Enum.map(fn item ->
            %{
              name: item["name"],
              path: item["path"],
              type: item["type"],
              size: item["size"],
              sha: item["sha"]
            }
          end)

        {:ok, entries}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Single file returned — wrap in a list
        {:ok,
         [
           %{
             name: body["name"],
             path: body["path"],
             type: body["type"],
             size: body["size"],
             sha: body["sha"]
           }
         ]}

      {:ok, %{status: 404, body: body}} ->
        {:error, %{status: 404, message: body["message"] || "Not found"}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

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
    url_path = "/repos/#{repo_id}/contents/#{path}"

    case Req.get(client(config), url: url_path, params: [ref: ref]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, decode_file_content(body)}

      {:ok, %{status: 404, body: body}} ->
        {:error, %{status: 404, message: body["message"] || "Not found"}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_file_content(%{"encoding" => "base64", "content" => content}) do
    case content |> String.replace(~r/\s/, "") |> Base.decode64() do
      {:ok, decoded} -> decoded
      :error -> ""
    end
  end

  defp decode_file_content(%{"content" => content}) when is_binary(content), do: content
  defp decode_file_content(_), do: ""

  @impl true
  def fetch_issues(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    state = Keyword.get(opts, :state, "open")

    params =
      [state: state]
      |> maybe_add_param(:per_page, Keyword.get(opts, :per_page))

    case Req.get(client(config), url: "/repos/#{repo_id}/issues", params: params) do
      {:ok, %{status: 200, body: body}} ->
        issues =
          body
          |> Enum.reject(fn item -> Map.has_key?(item, "pull_request") end)
          |> Enum.map(&normalize_issue/1)

        {:ok, issues}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_commits(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})

    params =
      []
      |> maybe_add_param(:sha, Keyword.get(opts, :sha))
      |> maybe_add_param(:path, Keyword.get(opts, :path))
      |> maybe_add_param(:per_page, Keyword.get(opts, :per_page))

    case Req.get(client(config), url: "/repos/#{repo_id}/commits", params: params) do
      {:ok, %{status: 200, body: body}} ->
        commits = Enum.map(body, &normalize_commit/1)
        {:ok, commits}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_merge_requests(repo_id, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    state = Keyword.get(opts, :state, "open")

    params = [state: state]

    case Req.get(client(config), url: "/repos/#{repo_id}/pulls", params: params) do
      {:ok, %{status: 200, body: body}} ->
        prs = Enum.map(body, &normalize_pull_request/1)
        {:ok, prs}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def search_code(query, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    repo = Keyword.get(opts, :repo)
    language = Keyword.get(opts, :language)

    q =
      [query, if(repo, do: "repo:#{repo}"), if(language, do: "language:#{language}")]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("+")

    case Req.get(client(config), url: "/search/code", params: [q: q]) do
      {:ok, %{status: 200, body: body}} ->
        results =
          (body["items"] || [])
          |> Enum.map(fn item ->
            %{
              name: item["name"],
              path: item["path"],
              sha: item["sha"],
              url: item["html_url"],
              repository: get_in(item, ["repository", "full_name"])
            }
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, message: body["message"] || "Unknown error"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def clone_url(repo_id) do
    "https://github.com/#{repo_id}.git"
  end

  # Normalization helpers

  defp normalize_repo(item) do
    %{
      id: to_string(item["id"]),
      full_name: item["full_name"],
      description: item["description"],
      url: item["html_url"],
      default_branch: item["default_branch"],
      language: item["language"],
      stars: item["stargazers_count"],
      updated_at: item["updated_at"]
    }
  end

  defp normalize_issue(item) do
    %{
      id: item["id"],
      number: item["number"],
      title: item["title"],
      state: item["state"],
      author: get_in(item, ["user", "login"]),
      labels: Enum.map(item["labels"] || [], & &1["name"]),
      created_at: item["created_at"],
      updated_at: item["updated_at"],
      url: item["html_url"]
    }
  end

  defp normalize_commit(item) do
    %{
      sha: item["sha"],
      message: get_in(item, ["commit", "message"]),
      author: get_in(item, ["commit", "author", "name"]),
      date: get_in(item, ["commit", "author", "date"]),
      url: item["html_url"]
    }
  end

  defp normalize_pull_request(item) do
    %{
      id: item["id"],
      number: item["number"],
      title: item["title"],
      state: item["state"],
      author: get_in(item, ["user", "login"]),
      source_branch: get_in(item, ["head", "ref"]),
      target_branch: get_in(item, ["base", "ref"]),
      created_at: item["created_at"],
      updated_at: item["updated_at"],
      url: item["html_url"]
    }
  end

  defp maybe_add_param(params, key, value), do: Backplane.Utils.maybe_put(params, key, value)
end
