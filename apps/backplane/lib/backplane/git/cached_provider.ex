defmodule Backplane.Git.CachedProvider do
  @moduledoc """
  Wraps Git.Provider calls with transparent response caching.

  Each provider endpoint has a configured TTL. On cache hit, the provider
  is not called. Webhook-triggered invalidation evicts all cached responses
  for the affected repo.
  """

  alias Backplane.Cache
  alias Backplane.Cache.KeyBuilder

  @endpoint_ttls %{
    "fetch_tree" => :timer.minutes(5),
    "fetch_file" => :timer.minutes(10),
    "fetch_issues" => :timer.minutes(2),
    "fetch_commits" => :timer.minutes(2),
    "fetch_merge_requests" => :timer.minutes(2),
    "search_code" => :timer.minutes(1),
    "list_repos" => :timer.minutes(1)
  }

  @doc """
  Execute a provider call with caching.

  On cache hit, returns the cached result without calling the provider.
  On cache miss, calls the function, caches successful results, and returns.

  ## Parameters
  - `module` — provider module (GitHub/GitLab)
  - `endpoint` — string like "fetch_tree", "fetch_file"
  - `repo_id` — "owner/repo" string
  - `params` — additional params for cache key differentiation (e.g., ref, path)
  - `fun` — zero-arity function to call on cache miss
  """
  @spec cached(module(), String.t(), String.t(), term(), (-> term())) :: term()
  def cached(module, endpoint, repo_id, params, fun) do
    unless Cache.enabled?() do
      fun.()
    else
      provider = provider_name(module)
      {owner, repo} = split_repo_id(repo_id)
      key = KeyBuilder.git(provider, owner, repo, endpoint, params)
      ttl = Map.get(@endpoint_ttls, endpoint, :timer.minutes(5))

      case Cache.get(key) do
        {:ok, cached_result} ->
          cached_result

        :miss ->
          result = fun.()

          case result do
            {:ok, _} -> Cache.put(key, result, ttl)
            _ -> :ok
          end

          result
      end
    end
  end

  @doc "Invalidate all cached responses for a repo."
  @spec invalidate_repo(String.t(), String.t(), String.t()) :: non_neg_integer()
  def invalidate_repo(provider, owner, repo) do
    prefix = KeyBuilder.git_repo_prefix(provider, owner, repo)
    Cache.invalidate_prefix(prefix)
  end

  @doc "Resolve the provider name string from a module."
  def provider_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
  end

  defp split_repo_id(repo_id) do
    case String.split(repo_id, "/", parts: 2) do
      [owner, repo] -> {owner, repo}
      [single] -> {single, ""}
    end
  end
end
