defmodule Backplane.Memory.Projections.EventOrder do
  @moduledoc false

  def sort(events) when is_list(events) do
    Enum.sort_by(events, &{&1.source_sequence, &1.event_type, &1.id})
  end

  # A durable Hermes UID identifies an occurrence. Repeated content without
  # that identity remains separate evidence; session snapshots are not rewinds.
  def current_inputs(events) when is_list(events) do
    events
    |> Enum.group_by(&message_identity/1)
    |> Enum.flat_map(fn
      {nil, unidentified} -> unidentified
      {_identity, revisions} -> [Enum.max_by(revisions, &revision_order/1)]
    end)
    |> sort()
  end

  defp message_identity(%{integration: integration, payload: %{"source" => source}} = event)
       when integration in ["hermes", "openclaw"] do
    values = [
      integration,
      source["installation_id"],
      source["profile_id"],
      event.session_id,
      source["message_uid"] || if(integration == "openclaw", do: source["occurrence_id"])
    ]

    if event.event_type in [
         "conversation.user_message",
         "conversation.agent_message",
         "agent.tool.completed"
       ] and
         Enum.all?(values, &(is_binary(&1) and &1 != "")),
       do: List.to_tuple(values)
  end

  defp message_identity(_event), do: nil

  defp revision_order(event) do
    revision = get_in(event.payload, ["source", "source_revision"])

    {if(is_integer(revision) and revision > 0, do: revision, else: 1), event.source_sequence,
     event.id}
  end
end
