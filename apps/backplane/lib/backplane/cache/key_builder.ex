defmodule Backplane.Cache.KeyBuilder do
  @moduledoc """
  Deterministic cache key construction for git API and upstream tool results.
  """

  @doc "Build a cache key for a git provider API call."
  @spec git(String.t(), String.t(), String.t(), String.t(), term()) :: tuple()
  def git(provider, owner, repo, endpoint, params \\ nil) do
    {:git, provider, owner, repo, endpoint, hash_params(params)}
  end

  @doc "Build a prefix key for invalidating all cached responses for a repo."
  @spec git_repo_prefix(String.t(), String.t(), String.t()) :: tuple()
  def git_repo_prefix(provider, owner, repo) do
    {:git, provider, owner, repo}
  end

  @doc "Build a cache key for an upstream tool call result."
  @spec upstream(String.t(), String.t(), map()) :: tuple()
  def upstream(prefix, tool_name, arguments) do
    {:upstream, prefix, tool_name, hash_params(arguments)}
  end

  @doc "Build a prefix key for invalidating all cached results for an upstream."
  @spec upstream_prefix(String.t()) :: tuple()
  def upstream_prefix(prefix) do
    {:upstream, prefix}
  end

  defp hash_params(nil), do: nil
  defp hash_params(params) when params == %{}, do: nil

  defp hash_params(params) when is_map(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_params(params) when is_list(params) do
    params
    |> Enum.sort()
    |> inspect()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_params(params) do
    params
    |> inspect()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
