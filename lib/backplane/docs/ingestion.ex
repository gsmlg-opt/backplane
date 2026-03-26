defmodule Backplane.Docs.Ingestion do
  @moduledoc """
  Orchestrates the documentation ingestion pipeline:
  clone/pull repo -> walk files -> parse -> chunk -> index -> update state.
  """

  require Logger

  alias Backplane.Docs.{Chunker, Indexer, Parser, Project}
  alias Backplane.Repo

  @doc_extensions ~w(.ex .exs .md .txt .rst .json .yml .yaml)

  @doc """
  Run the full ingestion pipeline for a project.
  """
  @spec run(String.t()) :: {:ok, map()} | {:error, term()}
  def run(project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :project_not_found}

      project ->
        run_pipeline(project)
    end
  end

  @doc """
  Run the pipeline for a project struct.
  """
  @spec run_pipeline(Project.t()) :: {:ok, map()} | {:error, term()}
  def run_pipeline(project) do
    Indexer.update_reindex_state(project.id, %{
      status: "running",
      started_at: DateTime.utc_now()
    })

    try do
      with {:ok, repo_path} <- ensure_repo(project),
           {:ok, commit_sha} <- get_commit_sha(repo_path),
           :changed <- check_sha_changed(project, commit_sha),
           {:ok, chunks} <- process_files(repo_path, project.id) do
        {:ok, stats} = Indexer.index(project.id, chunks)

        # Update project last_indexed_at (non-fatal if this fails)
        case project
             |> Project.changeset(%{
               last_indexed_at: DateTime.utc_now(),
               index_hash: commit_sha
             })
             |> Repo.update() do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "Failed to update project metadata: #{inspect(changeset.errors)}",
              project_id: project.id
            )
        end

        Indexer.update_reindex_state(project.id, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          commit_sha: commit_sha,
          chunk_count: stats.total
        })

        {:ok, stats}
      else
        :unchanged ->
          Logger.info("Skipping reindex — commit SHA unchanged",
            project_id: project.id
          )

          Indexer.update_reindex_state(project.id, %{
            status: "completed",
            completed_at: DateTime.utc_now()
          })

          {:ok, %{skipped: true, reason: :unchanged}}

        {:error, reason} = error ->
          Logger.error("Ingestion failed",
            project_id: project.id,
            reason: inspect(reason)
          )

          Indexer.update_reindex_state(project.id, %{
            status: "failed",
            completed_at: DateTime.utc_now()
          })

          error
      end
    rescue
      e ->
        Logger.error("Ingestion crashed",
          project_id: project.id,
          error: Exception.message(e)
        )

        Indexer.update_reindex_state(project.id, %{
          status: "failed",
          completed_at: DateTime.utc_now()
        })

        {:error, {:crash, Exception.message(e)}}
    end
  end

  @doc """
  Process all documentation files in a directory.
  Returns {:ok, processed_chunks}.
  """
  @spec process_files(String.t(), String.t()) :: {:ok, [map()]}
  def process_files(repo_path, project_id) do
    chunks =
      repo_path
      |> walk_files()
      |> Enum.flat_map(&parse_file(&1, repo_path, project_id))
      |> Chunker.process()

    {:ok, chunks}
  end

  defp parse_file(file_path, repo_path, project_id) do
    relative_path = Path.relative_to(file_path, repo_path)

    with {:ok, content} <- File.read(file_path),
         {:ok, parsed_chunks} <- Parser.parser_for(file_path).parse(content, relative_path) do
      parsed_chunks
    else
      {:error, reason} ->
        Logger.warning("Error processing file",
          path: relative_path,
          project_id: project_id,
          reason: inspect(reason)
        )

        []

      other ->
        Logger.warning("Unexpected parse result",
          path: relative_path,
          project_id: project_id,
          result: inspect(other)
        )

        []
    end
  end

  defp ensure_repo(project) do
    clone_dir = clone_path(project.id)

    if File.dir?(Path.join(clone_dir, ".git")) do
      pull_repo(clone_dir, project.ref)
    else
      clone_repo(project.repo, clone_dir, project.ref)
    end
  end

  defp clone_repo(repo_url, dest, ref) do
    File.mkdir_p!(dest)

    case System.cmd("git", ["clone", "--branch", ref, "--depth", "1", repo_url, dest],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, dest}
      {output, _} -> {:error, {:clone_failed, output}}
    end
  end

  defp pull_repo(repo_path, ref) do
    case System.cmd("git", ["fetch", "origin", ref],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        case System.cmd("git", ["reset", "--hard", "origin/#{ref}"],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {_output, 0} -> {:ok, repo_path}
          {output, _} -> {:error, {:pull_failed, output}}
        end

      {output, _} ->
        {:error, {:fetch_failed, output}}
    end
  end

  defp get_commit_sha(repo_path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {output, _} -> {:error, {:sha_failed, output}}
    end
  end

  defp check_sha_changed(project, commit_sha) do
    if project.index_hash == commit_sha do
      :unchanged
    else
      :changed
    end
  end

  defp walk_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      File.regular?(path) and Path.extname(path) in @doc_extensions
    end)
    |> Enum.reject(fn path ->
      # Skip common non-doc directories
      parts = Path.split(path)

      Enum.any?(parts, fn part ->
        part in ~w(.git _build deps node_modules .elixir_ls)
      end)
    end)
  end

  defp clone_path(project_id) do
    base = Application.get_env(:backplane, :clone_dir, "/tmp/backplane_repos")
    Path.join(base, project_id)
  end
end
