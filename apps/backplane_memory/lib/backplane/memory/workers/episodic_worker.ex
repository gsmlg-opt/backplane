defmodule Backplane.Memory.Workers.EpisodicWorker do
  @moduledoc "Oban worker: extract semantic memories from session summary (episodic → semantic)."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Projections.ProjectedSession

  @processing_version "episodic-v1"

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("episodic", job.args, fn ->
      do_perform(job)
    end)
  end

  defp do_perform(%Oban.Job{args: %{"summary_id" => summary_id} = args})
       when is_binary(summary_id) and map_size(args) == 1 do
    with {:ok, summary_id} <- Ecto.UUID.cast(summary_id) do
      run_summary(repo().get(Summary, summary_id))
    else
      :error -> {:cancel, :invalid_arguments}
    end
  end

  defp do_perform(%Oban.Job{args: %{"session_id" => session_id} = args})
       when is_binary(session_id) and map_size(args) == 1 do
    if String.trim(session_id) == "" do
      {:cancel, :invalid_arguments}
    else
      perform_legacy(session_id)
    end
  end

  defp do_perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  defp perform_legacy(session_id) do
    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] episodic worker: skipping, no llm_model configured")
        :ok

      _model ->
        do_extract_legacy(session_id, llm_module)
    end
  end

  defp do_extract_legacy(session_id, llm_module) do
    summary =
      repo().one(
        from(s in Summary,
          where:
            s.session_id == ^session_id and s.host_id == "legacy" and
              s.processing_version == "legacy-v0",
          limit: 1
        )
      )

    extract(summary, llm_module)
  end

  defp run_summary(nil), do: :ok

  defp run_summary(%Summary{} = summary) do
    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] episodic worker: skipping, no llm_model configured")
        :ok

      _model ->
        llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)
        extract(summary, llm_module)
    end
  end

  defp extract(summary, llm_module) do
    case summary do
      nil ->
        :ok

      %Summary{} = summary ->
        content = summary.content
        partition = projected_partition(summary)

        case llm_module.extract_facts(content) do
          {:ok, facts} when is_list(facts) ->
            require Logger

            errors =
              facts
              |> normalize_outputs()
              |> Enum.with_index()
              |> Enum.flat_map(fn {fact, ordinal} ->
                case Memories.remember(fact,
                       type: "semantic",
                       scope: partition.scope,
                       namespace: partition.namespace,
                       client_id: partition.client_id,
                       agent_id: summary.agent_id || "consolidation",
                       host_id: summary.host_id,
                       session_id: summary.session_id,
                       idempotency_scope: "memory-worker:episodic",
                       idempotency_key: idempotency_key(summary, ordinal),
                       evidence: [summary_evidence(summary)]
                     ) do
                  {:ok, _} -> []
                  {:error, reason} -> [reason]
                end
              end)

            case errors do
              [] ->
                :ok

              [first | rest] ->
                Logger.warning(
                  "[memory] episodic worker: #{length(rest) + 1} fact(s) failed to insert"
                )

                {:error, first}
            end

          {:skip, _} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_outputs(outputs) do
    outputs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp idempotency_key(summary, ordinal) do
    revision = sha256(summary.content)
    Enum.join([@processing_version, summary.id, revision, ordinal], ":")
  end

  defp summary_evidence(summary) do
    %{
      source_summary_id: summary.id,
      session_id: summary.session_id,
      agent_id: summary.agent_id || "consolidation",
      host_id: summary.host_id,
      evidence_kind: "derives",
      support_score: 1.0,
      excerpt: String.slice(summary.content, 0, 1_000)
    }
  end

  defp projected_partition(%Summary{subject_id: subject_id, project: project}) do
    case repo().get(ProjectedSession, subject_id) do
      %ProjectedSession{} = session ->
        %{scope: session.scope, namespace: session.namespace, client_id: session.client_id}

      nil ->
        %{scope: project, namespace: "private", client_id: nil}
    end
  end

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc "Enqueue an episodic extraction job for the given session_id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(session_id) do
    %{session_id: session_id}
    |> new()
    |> Oban.insert()
  end

  @doc "Enqueue extraction for one exact durable summary revision."
  @spec enqueue_summary(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_summary(summary_id) when is_binary(summary_id) do
    %{summary_id: summary_id}
    |> new(unique: [period: :infinity, states: :incomplete, keys: [:summary_id]])
    |> Oban.insert()
  end
end
