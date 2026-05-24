defmodule BackplaneMemory.Workers.ProceduralWorker do
  @moduledoc "Oban worker: extract procedural memories from semantic memories (semantic → procedural). Nightly cron."

  use Oban.Worker, queue: :memory, max_attempts: 2

  import Ecto.Query
  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Memory

  @min_semantic_count 10

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    llm_module = Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)

    case Backplane.Settings.get("memory.llm_model") do
      nil ->
        require Logger
        Logger.debug("[memory] procedural worker: skipping, no llm_model configured")
        :ok

      _model ->
        do_extract_procedural(llm_module)
    end
  end

  defp do_extract_procedural(llm_module) do
    scopes =
      repo().all(
        from(m in MemorySchema,
          where: m.memory_type == "semantic" and is_nil(m.deleted_at) and not is_nil(m.scope),
          group_by: m.scope,
          having: count(m.id) >= @min_semantic_count,
          select: m.scope
        )
      )

    require Logger

    Enum.each(scopes, fn scope ->
      memories =
        repo().all(
          from(m in MemorySchema,
            where: m.memory_type == "semantic" and m.scope == ^scope and is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: 30,
            select: m.content
          )
        )

      case llm_module.extract_procedures(Enum.join(memories, "\n")) do
        {:ok, procedures} when is_list(procedures) ->
          Enum.each(procedures, fn procedure ->
            case Memory.remember(procedure,
                   type: "procedural",
                   scope: scope,
                   agent_id: "consolidation",
                   host_id: "system"
                 ) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning("[memory] procedural worker: failed to insert: #{inspect(reason)}")
            end
          end)

        {:error, reason} ->
          Logger.warning(
            "[memory] procedural worker: LLM extract failed for scope=#{scope}: #{inspect(reason)}"
          )

        _ ->
          :ok
      end
    end)

    :ok
  end
end
