defmodule Backplane.Git.Provider do
  @moduledoc """
  Behaviour for Git platform providers (GitHub, GitLab, etc.).
  All providers normalize responses to a common shape.
  """

  @callback list_repos(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_tree(repo_id :: String.t(), ref :: String.t(), path :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_file(repo_id :: String.t(), path :: String.t(), ref :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  @callback fetch_issues(repo_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_commits(repo_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_merge_requests(repo_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback search_code(query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback clone_url(repo_id :: String.t()) :: String.t()
end
