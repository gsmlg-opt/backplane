defmodule Backplane.Tools.Git do
  @moduledoc """
  Native MCP tools for the Git Platform Proxy.
  Registers: git::search-repos, git::repo-tree, git::repo-file,
             git::repo-issues, git::repo-commits, git::repo-merge-requests,
             git::search-code
  """

  alias Backplane.Git.Resolver

  def tools do
    [
      %{
        name: "git::search-repos",
        description: "Search repositories across configured git providers",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "provider" => %{
              "type" => "string",
              "description" =>
                "Provider prefix (e.g., 'github', 'gitlab', 'github.enterprise'). Searches all configured providers if omitted."
            },
            "query" => %{
              "type" => "string",
              "description" => "Search query for repository names/descriptions"
            }
          },
          "required" => ["query"]
        },
        module: __MODULE__,
        handler: :search_repos
      },
      %{
        name: "git::repo-tree",
        description:
          "List files and directories at a path in a repository. Repo format: 'provider:owner/repo' (e.g., 'github:elixir-lang/elixir')",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "Repository identifier (e.g., 'github:owner/repo')"
            },
            "path" => %{
              "type" => "string",
              "description" => "Path within the repository (default: root)"
            },
            "ref" => %{
              "type" => "string",
              "description" => "Git ref: branch, tag, or commit SHA (default: main)"
            }
          },
          "required" => ["repo"]
        },
        module: __MODULE__,
        handler: :repo_tree
      },
      %{
        name: "git::repo-file",
        description:
          "Get the content of a file from a repository. Repo format: 'provider:owner/repo'",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "Repository identifier (e.g., 'github:owner/repo')"
            },
            "path" => %{
              "type" => "string",
              "description" => "File path within the repository"
            },
            "ref" => %{
              "type" => "string",
              "description" => "Git ref: branch, tag, or commit SHA (default: main)"
            }
          },
          "required" => ["repo", "path"]
        },
        module: __MODULE__,
        handler: :repo_file
      },
      %{
        name: "git::repo-issues",
        description: "List issues in a repository. Repo format: 'provider:owner/repo'",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "Repository identifier (e.g., 'github:owner/repo')"
            },
            "state" => %{
              "type" => "string",
              "description" => "Filter by state: open, closed, all (default: open)"
            }
          },
          "required" => ["repo"]
        },
        module: __MODULE__,
        handler: :repo_issues
      },
      %{
        name: "git::repo-commits",
        description: "List recent commits in a repository. Repo format: 'provider:owner/repo'",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "Repository identifier (e.g., 'github:owner/repo')"
            },
            "sha" => %{
              "type" => "string",
              "description" => "Branch name or commit SHA to list from"
            },
            "path" => %{
              "type" => "string",
              "description" => "Filter commits affecting this file path"
            },
            "per_page" => %{
              "type" => "integer",
              "description" => "Number of commits to return (default: 30)"
            }
          },
          "required" => ["repo"]
        },
        module: __MODULE__,
        handler: :repo_commits
      },
      %{
        name: "git::repo-merge-requests",
        description:
          "List pull requests / merge requests in a repository. Repo format: 'provider:owner/repo'",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "Repository identifier (e.g., 'github:owner/repo')"
            },
            "state" => %{
              "type" => "string",
              "description" => "Filter by state: open, closed, merged, all (default: open)"
            }
          },
          "required" => ["repo"]
        },
        module: __MODULE__,
        handler: :repo_merge_requests
      },
      %{
        name: "git::search-code",
        description: "Search for code across repositories. Repo format: 'provider:owner/repo'",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Code search query"
            },
            "repo" => %{
              "type" => "string",
              "description" =>
                "Repository identifier to search within (e.g., 'github:owner/repo')"
            },
            "language" => %{
              "type" => "string",
              "description" => "Filter by programming language"
            }
          },
          "required" => ["query"]
        },
        module: __MODULE__,
        handler: :search_code
      }
    ]
  end

  def call(%{"_handler" => "search_repos"} = args) do
    provider = args["provider"]
    query = args["query"]

    if provider do
      # Search specific provider
      case Resolver.resolve("#{provider}:_placeholder") do
        {:ok, {module, config, _repo_id}} ->
          module.list_repos(config: config, query: query)

        {:error, reason} ->
          {:error, "Failed to resolve provider '#{provider}': #{inspect(reason)}"}
      end
    else
      # Search all configured providers
      search_all_providers(query)
    end
  end

  def call(%{"_handler" => "repo_tree"} = args) do
    repo = args["repo"]
    path = args["path"] || ""
    ref = args["ref"] || "main"

    with_resolved_repo(repo, fn module, config, repo_id ->
      module.fetch_tree(repo_id, ref, path, config: config)
    end)
  end

  def call(%{"_handler" => "repo_file"} = args) do
    repo = args["repo"]
    path = args["path"]
    ref = args["ref"] || "main"

    with_resolved_repo(repo, fn module, config, repo_id ->
      module.fetch_file(repo_id, path, ref, config: config)
    end)
  end

  def call(%{"_handler" => "repo_issues"} = args) do
    repo = args["repo"]
    state = args["state"] || "open"

    with_resolved_repo(repo, fn module, config, repo_id ->
      module.fetch_issues(repo_id, config: config, state: state)
    end)
  end

  def call(%{"_handler" => "repo_commits"} = args) do
    repo = args["repo"]

    with_resolved_repo(repo, fn module, config, repo_id ->
      opts =
        [config: config]
        |> maybe_add(:sha, args["sha"])
        |> maybe_add(:path, args["path"])
        |> maybe_add(:per_page, args["per_page"])

      module.fetch_commits(repo_id, opts)
    end)
  end

  def call(%{"_handler" => "repo_merge_requests"} = args) do
    repo = args["repo"]
    state = args["state"] || "open"

    with_resolved_repo(repo, fn module, config, repo_id ->
      module.fetch_merge_requests(repo_id, config: config, state: state)
    end)
  end

  def call(%{"_handler" => "search_code"} = args) do
    query = args["query"]
    repo_string = args["repo"]
    language = args["language"]

    if repo_string do
      with_resolved_repo(repo_string, fn module, config, repo_id ->
        module.search_code(query, config: config, repo: repo_id, language: language)
      end)
    else
      search_code_all_providers(query, language)
    end
  end

  def call(args) do
    {:error, "Unknown git tool handler: #{inspect(args)}"}
  end

  @provider_modules %{
    github: Backplane.Git.Providers.GitHub,
    gitlab: Backplane.Git.Providers.GitLab
  }

  # Search repos across all configured providers
  defp search_all_providers(query) do
    results =
      for_each_provider_instance(fn module, config ->
        case module.list_repos(config: config, query: query) do
          {:ok, repos} -> repos
          {:error, _} -> []
        end
      end)

    {:ok, results}
  end

  defp search_code_all_providers(query, language) do
    results =
      for_each_provider_instance(fn module, config ->
        case module.search_code(query, config: config, language: language) do
          {:ok, items} -> items
          {:error, _} -> []
        end
      end)

    {:ok, results}
  end

  defp for_each_provider_instance(callback) do
    providers = Application.get_env(:backplane, :git_providers, %{})

    Enum.flat_map([:github, :gitlab], fn type ->
      module = Map.fetch!(@provider_modules, type)
      instances = Map.get(providers, type, [])

      Enum.flat_map(instances, fn instance ->
        config = %{token: instance.token, api_url: instance.api_url}
        callback.(module, config)
      end)
    end)
  end

  defp with_resolved_repo(repo, fun) do
    case Resolver.resolve(repo) do
      {:ok, {module, config, repo_id}} -> fun.(module, config, repo_id)
      {:error, reason} -> {:error, "Failed to resolve repo '#{repo}': #{inspect(reason)}"}
    end
  end

  defp maybe_add(opts, key, value), do: Backplane.Utils.maybe_put(opts, key, value)
end
