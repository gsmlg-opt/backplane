defmodule Backplane.Jobs.WebhookHandler do
  @moduledoc """
  Oban worker for processing webhook events from GitHub and GitLab.
  Matches push events to configured projects and enqueues reindex jobs.
  """

  use Oban.Worker, queue: :default

  require Logger

  alias Backplane.Docs.Project
  alias Backplane.Jobs.Reindex
  alias Backplane.Repo

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => "github", "event" => "push"} = args}) do
    repo_url = args["repo_url"]
    ref = args["ref"]

    handle_push(repo_url, ref)
  end

  def perform(%Oban.Job{args: %{"provider" => "gitlab", "event" => "push"} = args}) do
    repo_url = args["repo_url"]
    ref = args["ref"]

    handle_push(repo_url, ref)
  end

  def perform(%Oban.Job{args: args}) do
    Logger.debug("Ignoring webhook event: #{inspect(args)}")
    :ok
  end

  @doc """
  Enqueue a webhook event for processing.
  """
  def enqueue(:github, params) do
    case extract_github_push(params) do
      {:ok, attrs} ->
        attrs
        |> Map.put("provider", "github")
        |> Map.put("event", "push")
        |> __MODULE__.new()
        |> Oban.insert()

      :ignore ->
        {:ok, :ignored}
    end
  end

  def enqueue(:gitlab, params) do
    case extract_gitlab_push(params) do
      {:ok, attrs} ->
        attrs
        |> Map.put("provider", "gitlab")
        |> Map.put("event", "push")
        |> __MODULE__.new()
        |> Oban.insert()

      :ignore ->
        {:ok, :ignored}
    end
  end

  @doc """
  Validate a GitHub webhook signature.
  """
  def validate_github_signature(payload, signature, secret) do
    expected =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower))

    Plug.Crypto.secure_compare(expected, signature)
  end

  @doc """
  Validate a GitLab webhook token.
  """
  def validate_gitlab_token(token, expected) do
    Plug.Crypto.secure_compare(token, expected)
  end

  # Private

  defp handle_push(repo_url, ref) do
    branch = extract_branch(ref)

    projects = find_matching_projects(repo_url, branch)

    Enum.each(projects, fn project ->
      %{"project_id" => project.id}
      |> Reindex.new()
      |> Oban.insert()
    end)

    :ok
  end

  defp find_matching_projects(repo_url, branch) do
    # Match by repo URL and ref
    Project
    |> where([p], p.repo == ^repo_url and p.ref == ^branch)
    |> Repo.all()
  end

  defp extract_branch("refs/heads/" <> branch), do: branch
  defp extract_branch(ref), do: ref

  defp extract_github_push(%{"ref" => ref, "repository" => %{"clone_url" => url}}) do
    {:ok, %{"ref" => ref, "repo_url" => url}}
  end

  defp extract_github_push(%{"ref" => ref, "repository" => %{"html_url" => url}}) do
    {:ok, %{"ref" => ref, "repo_url" => url <> ".git"}}
  end

  defp extract_github_push(_), do: :ignore

  defp extract_gitlab_push(%{"ref" => ref, "project" => %{"git_http_url" => url}}) do
    {:ok, %{"ref" => ref, "repo_url" => url}}
  end

  defp extract_gitlab_push(_), do: :ignore
end
