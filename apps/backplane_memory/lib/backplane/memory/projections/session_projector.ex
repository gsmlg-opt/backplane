defmodule Backplane.Memory.Projections.SessionProjector do
  @moduledoc "Pure deterministic captured-session projection."

  alias Backplane.Memory.Projections.{EventOrder, ObservationProjector, Source}

  def project(events, gaps) when is_list(events) and is_list(gaps) do
    ordered = EventOrder.sort(events)
    first = List.first(ordered)

    %{
      "subject_id" => subject_id(first),
      "host_id" => field(first, :host_id),
      "client_id" => field(first, :client_id),
      "scope" => field(first, :scope),
      "namespace" => field(first, :namespace),
      "session_id" => field(first, :session_id),
      "project" => first_value(ordered, :project),
      "agent_id" => first_value(ordered, :agent_id),
      "status" => lifecycle_status(ordered),
      "started_at" => started_at(ordered),
      "ended_at" => ended_at(ordered),
      "last_event_at" => last_event_at(ordered),
      "source_sequence_max" => source_sequence_max(ordered),
      "counts" => counts(ordered),
      "source_event_ids" => Enum.map(ordered, & &1.id),
      "gaps" => Enum.sort(gaps)
    }
  end

  defp counts(events) do
    tool_names = events |> Enum.map(&ObservationProjector.tool_name/1) |> Enum.reject(&is_nil/1)

    %{
      "events" => length(events),
      "tools" => length(tool_names),
      "errors" => Enum.count(events, &ObservationProjector.error?/1),
      "by_event_type" => events |> Enum.map(& &1.event_type) |> Enum.frequencies(),
      "by_tool" => Enum.frequencies(tool_names)
    }
  end

  defp lifecycle_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value("active", fn event ->
      case event.event_type do
        "agent.session.abandoned" -> "abandoned"
        type when type in ["agent.session.ended", "session.ended"] -> "completed"
        "agent.session.stopped" -> "stopped"
        type when type in ["agent.session.started", "session.started"] -> "active"
        _type -> nil
      end
    end)
  end

  defp started_at([]), do: nil

  defp started_at(events) do
    events
    |> Enum.find(
      List.first(events),
      &(&1.event_type in ["agent.session.started", "session.started"])
    )
    |> then(&iso8601(&1.occurred_at))
  end

  defp ended_at(events) do
    events
    |> Enum.reverse()
    |> Enum.find(
      &(&1.event_type in [
          "agent.session.abandoned",
          "agent.session.ended",
          "session.ended",
          "agent.session.stopped"
        ])
    )
    |> case do
      nil -> nil
      event -> iso8601(event.occurred_at)
    end
  end

  defp last_event_at([]), do: nil
  defp last_event_at(events), do: events |> List.last() |> then(&iso8601(&1.occurred_at))

  defp source_sequence_max(events) do
    events
    |> Enum.map(& &1.source_sequence)
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp subject_id(nil), do: nil

  defp subject_id(event) do
    case Source.subject_id(event.host_id, event.session_id) do
      {:ok, subject_id} -> subject_id
      {:error, _reason} -> nil
    end
  end

  defp first_value(events, field) do
    Enum.find_value(events, fn event ->
      case Map.get(event, field) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        _ -> nil
      end
    end)
  end

  defp field(nil, _field), do: nil
  defp field(event, field), do: Map.get(event, field)
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
end
