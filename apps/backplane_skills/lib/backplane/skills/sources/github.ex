defmodule Backplane.Skills.Sources.GitHub do
  @moduledoc """
  GitHub-backed skill source.

  Fetches skills from a GitHub repository by scanning for SKILL.md files
  under the configured path prefix.
  """

  alias Backplane.Skills.Loader
  alias Backplane.Skills.SkillSource

  require Logger

  @doc """
  List skills available in a GitHub repository.
  Uses the GitHub API to discover SKILL.md files in the repo tree.
  """
  @spec list_skills(SkillSource.t()) :: {:ok, [map()]} | {:error, term()}
  def list_skills(%SkillSource{url: url, branch: branch, path_prefix: path_prefix}) do
    with {:ok, owner, repo} <- parse_github_url(url),
         {:ok, tree} <- fetch_tree(owner, repo, branch) do
      prefix = String.trim_trailing(path_prefix || "skills/", "/")

      skill_files =
        tree
        |> Enum.filter(fn entry ->
          path = entry["path"] || ""

          String.starts_with?(path, prefix) and
            String.ends_with?(String.downcase(path), "skill.md") and
            entry["type"] == "blob"
        end)

      skills =
        skill_files
        |> Task.async_stream(
          fn entry ->
            fetch_and_parse_skill(owner, repo, branch, entry["path"])
          end,
          max_concurrency: 5,
          timeout: 15_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, skill}} -> [skill]
          {:ok, {:error, reason}} ->
            Logger.warning("Failed to parse skill: #{inspect(reason)}")
            []
          {:exit, _reason} -> []
        end)

      {:ok, skills}
    end
  end

  @doc "Fetch a single skill file content from GitHub."
  @spec fetch_skill(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_skill(owner, repo, branch, path) do
    fetch_and_parse_skill(owner, repo, branch, path)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp parse_github_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri do
      %URI{host: host, path: path}
      when host in ["github.com", "www.github.com"] and is_binary(path) ->
        segments =
          path
          |> String.trim("/")
          |> String.replace(~r/\.git$/, "")
          |> String.split("/")

        case segments do
          [owner, repo | _] when owner != "" and repo != "" ->
            {:ok, owner, repo}

          _ ->
            {:error, :invalid_github_url}
        end

      _ ->
        {:error, :invalid_github_url}
    end
  end

  defp parse_github_url(_), do: {:error, :invalid_github_url}

  defp fetch_tree(owner, repo, branch) do
    url = "https://api.github.com/repos/#{owner}/#{repo}/git/trees/#{branch}?recursive=1"

    headers = github_headers()

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: %{"tree" => tree}}} ->
        {:ok, tree}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :repo_not_found}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp fetch_and_parse_skill(owner, repo, branch, path) do
    url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{branch}/#{path}"

    case Req.get(url, headers: github_headers(), receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Loader.parse(body) do
          {:ok, entry} ->
            # Derive a slug from the path
            slug = path_to_slug(path)

            {:ok,
             Map.merge(entry, %{
               slug: slug,
               source_path: path,
               source_kind: "github"
             })}

          {:error, reason} ->
            {:error, {:parse_error, path, reason}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:fetch_error, path, status}}

      {:error, reason} ->
        {:error, {:request_failed, path, reason}}
    end
  end

  defp path_to_slug(path) do
    # e.g. "skills/my-skill/SKILL.md" -> "my-skill"
    path
    |> Path.dirname()
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "skill"
      slug -> slug
    end
  end

  defp github_headers do
    token = github_token()

    headers = [
      {"accept", "application/vnd.github.v3+json"},
      {"user-agent", "Backplane-Skills/1.0"}
    ]

    if token do
      [{"authorization", "Bearer #{token}"} | headers]
    else
      headers
    end
  end

  defp github_token do
    # Try to load a GitHub token from credentials
    case Backplane.Settings.Credentials.fetch("github_token") do
      {:ok, token} when is_binary(token) and token != "" -> token
      _ -> System.get_env("GITHUB_TOKEN")
    end
  rescue
    _ -> System.get_env("GITHUB_TOKEN")
  end
end
