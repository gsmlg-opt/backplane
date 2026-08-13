defmodule Backplane.Memory.Memories.EvidenceInheritance do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Memories.Evidence

  @source_fields [
    :source_event_id,
    :source_observation_id,
    :source_summary_id,
    :source_session_id
  ]

  def roots_by_memory(memory_ids, opts) when is_list(memory_ids) do
    limit = Keyword.fetch!(opts, :limit)

    rows =
      Evidence
      |> where([e], e.memory_id in ^memory_ids)
      |> where(
        [e],
        not is_nil(e.source_event_id) or not is_nil(e.source_observation_id) or
          not is_nil(e.source_summary_id) or not is_nil(e.source_session_id)
      )
      |> order_by([e], asc: e.created_at, asc: e.id)
      |> limit(^(limit + 1))
      |> repo().all()

    if length(rows) > limit do
      {:error, :evidence_limit_exceeded}
    else
      {:ok, Enum.group_by(rows, & &1.memory_id, &root_attrs/1)}
    end
  end

  defp root_attrs(evidence) do
    evidence
    |> Map.from_struct()
    |> Map.take(@source_fields ++ [:session_id, :agent_id, :host_id, :support_score, :excerpt])
    |> Map.put(:evidence_kind, "derives")
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
