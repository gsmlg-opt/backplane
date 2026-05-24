defmodule BackplaneMemory.Workers.EpisodicWorker do
  @moduledoc "Oban worker: extract semantic memories from session summary (episodic → semantic)."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Consolidation.Summary
  alias BackplaneMemory.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    llm_module = Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)

    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] episodic worker: skipping, no llm_model configured")
        :ok

      _model ->
        do_extract(session_id, llm_module)
    end
  end

  defp do_extract(session_id, llm_module) do
    summary = repo().one(from(s in Summary, where: s.session_id == ^session_id, limit: 1))

    case summary do
      nil ->
        :ok

      %Summary{content: content, project: project} ->
        case llm_module.extract_facts(content) do
          {:ok, facts} when is_list(facts) ->
            require Logger

            errors =
              Enum.flat_map(facts, fn fact ->
                case Memory.remember(fact,
                       type: "semantic",
                       scope: project,
                       agent_id: "consolidation",
                       host_id: "system"
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

  @doc "Enqueue an episodic extraction job for the given session_id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(session_id) do
    %{session_id: session_id}
    |> new()
    |> Oban.insert()
  end
end
