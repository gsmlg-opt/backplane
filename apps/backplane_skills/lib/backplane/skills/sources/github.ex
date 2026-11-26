defmodule Backplane.Skills.Sources.GitHub do
  @moduledoc """
  GitHub-backed skill source.

  Fetches skills from a GitHub repository by scanning for SKILL.md files
  under the configured path prefix.
  """

  alias Backplane.SkillProtocol.{Bundle, TemporaryStorage}
  alias Backplane.HTTPClient
  alias Backplane.HTTPClient.Response
  alias Backplane.Skills.Loader
  alias Backplane.Skills.SkillSource

  @doc """
  List skills available in a GitHub repository.
  Uses the GitHub API to discover SKILL.md files in the repo tree.
  """
  @spec list_skills(SkillSource.t()) :: {:ok, [map()]} | {:error, term()}
  def list_skills(%SkillSource{url: url, branch: branch, path_prefix: path_prefix}) do
    with {:ok, owner, repo} <- parse_github_url(url),
         {:ok, commit} <- fetch_commit(owner, repo, branch),
         {:ok, tree} <- fetch_tree(owner, repo, commit) do
      prefix = String.trim(path_prefix || "skills", "/")

      roots =
        Enum.filter(tree, fn entry ->
          path = entry["path"]

          entry["type"] == "blob" and Path.basename(path) == "SKILL.md" and
            (prefix == "" or String.starts_with?(path, prefix <> "/"))
        end)

      identities = Enum.map(roots, &root_identity(&1["path"], commit, tree))

      results =
        Task.async_stream(
          identities,
          fn identity ->
            fetch_and_parse_skill(owner, repo, commit, identity.source_path)
          end,
          max_concurrency: 5,
          timeout: 20_000,
          on_timeout: :kill_task
        )

      entries =
        Enum.zip_with(identities, results, fn identity, result ->
          case result do
            {:ok, {:ok, entry}} -> Map.merge(entry, identity)
            {:ok, {:error, reason}} -> failed_document(identity, reason)
            {:exit, _reason} -> failed_document(identity, :unavailable_document)
          end
        end)

      {:ok, entries}
    end
  end

  defp root_identity(path, commit, tree) do
    directory = Path.dirname(path)
    prefix = if directory == ".", do: "", else: directory <> "/"
    files = Enum.filter(tree, &(String.starts_with?(&1["path"], prefix) and &1["type"] != "tree"))
    %{source_path: path, source_rev: commit, slug: path_to_slug(path), files: files}
  end

  defp failed_document(identity, reason),
    do: Map.merge(identity, %{name: identity.slug, description: "", error: reason})

  defp fetch_commit(owner, repo, branch) do
    url =
      "https://api.github.com/repos/#{owner}/#{repo}/commits/#{URI.encode(branch || "HEAD", &URI.char_unreserved?/1)}"

    case request(url, headers: github_headers(), max_body_bytes: 8_388_608) do
      {:ok, %Response{status: 200, body: %{"sha" => sha}}} when is_binary(sha) ->
        if Regex.match?(~r/^[a-f0-9]{40}$/, sha), do: {:ok, sha}, else: {:error, :invalid_commit}

      {:ok, %Response{status: code}} ->
        {:error, {:github_commit, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Download and pack one complete root from the listed immutable commit."
  def with_bundle(source, entry, callback) do
    with {:ok, owner, repo} <- parse_github_url(source.url),
         :ok <- valid_inventory(entry),
         {:ok, tmp} <- TemporaryStorage.directory(System.tmp_dir!(), "github-skill") do
      root = Path.join(tmp, entry.name)

      try do
        with :ok <- File.mkdir(root),
             :ok <- download_files(owner, repo, entry, root),
             {:ok, bundle} <- Bundle.pack(root, Path.join(tmp, "archive.tar.gz")) do
          callback.(bundle)
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp valid_inventory(entry) do
    regular = fn file ->
      file["type"] == "blob" and file["mode"] in ["100644", "100755"] and
        is_integer(file["size"]) and file["size"] in 0..8_388_608
    end

    if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, entry.name) and
         length(entry.files) in 1..1000 and Enum.all?(entry.files, regular) and
         Enum.sum(Enum.map(entry.files, & &1["size"])) <= 67_108_864 do
      :ok
    else
      {:error, :invalid_bundle_inventory}
    end
  end

  defp download_files(owner, repo, entry, root) do
    directory = Path.dirname(entry.source_path)
    prefix = if directory == ".", do: "", else: directory <> "/"

    Enum.reduce_while(entry.files, :ok, fn file, :ok ->
      path = file["path"]
      relative = String.replace_prefix(path, prefix, "")
      destination = Path.join(root, relative)
      url = raw_url(owner, repo, entry.source_rev, path)

      result =
        with true <-
               String.starts_with?(path, prefix) and
                 not Enum.any?(String.split(relative, "/"), &(&1 in ["", ".", ".."])) and
                 not String.contains?(relative, ["\\", <<0>>]),
             {:ok, %Response{status: 200, body: bytes}} when is_binary(bytes) <-
               request(url,
                 headers: github_headers(),
                 raw: true,
                 redirect: false,
                 max_body_bytes: max(1, file["size"])
               ),
             true <- byte_size(bytes) == file["size"],
             :ok <- File.mkdir_p(Path.dirname(destination)),
             :ok <- File.write(destination, bytes, [:exclusive]),
             do: :ok

      case result do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, {:unavailable_bundle_file, relative}}}
      end
    end)
  end

  defp raw_url(owner, repo, revision, path) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "https://raw.githubusercontent.com/#{owner}/#{repo}/#{revision}/#{encoded}"
  end

  @doc "Fetch a single skill file content from GitHub."
  @spec fetch_skill(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
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

    case request(url, headers: headers, receive_timeout: 15_000, max_body_bytes: 16_777_216) do
      {:ok, %Response{status: 200, body: %{"truncated" => true}}} ->
        {:error, :incomplete_tree}

      {:ok, %Response{status: 200, body: %{"tree" => tree}}} ->
        {:ok, tree}

      {:ok, %Response{status: 404}} ->
        {:error, :repo_not_found}

      {:ok, %Response{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %Response{status: status}} ->
        {:error, {:github_api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp fetch_and_parse_skill(owner, repo, branch, path) do
    url = raw_url(owner, repo, branch, path)

    case request(url,
           headers: github_headers(),
           raw: true,
           redirect: false,
           max_body_bytes: 2_097_152,
           receive_timeout: 10_000
         ) do
      {:ok, %Response{status: 200, body: body}} when is_binary(body) ->
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

      {:ok, %Response{status: status}} ->
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

  defp request(url, opts) do
    opts =
      case Application.get_env(:backplane_skills, :github_http_adapter) do
        nil -> opts
        adapter -> Keyword.put(opts, :adapter, adapter)
      end

    HTTPClient.get(url, opts)
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
