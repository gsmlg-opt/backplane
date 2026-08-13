defmodule Backplane.Memory.Projections.ActivityProjector do
  @moduledoc "Pure deterministic daily activity aggregation."

  alias Backplane.Memory.Projections.ObservationProjector

  def project(events) when is_list(events) do
    events
    |> Enum.group_by(&group_key/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {
                     {date, project, agent_id, host_id, client_id, scope, namespace, event_type},
                     grouped
                   } ->
      %{
        "date" => date,
        "project" => project,
        "agent_id" => agent_id,
        "host_id" => host_id,
        "client_id" => client_id,
        "scope" => scope,
        "namespace" => namespace,
        "event_type" => event_type,
        "event_count" => length(grouped),
        "session_count" => session_count(grouped),
        "memory_count" => count(grouped, :memory),
        "lesson_count" => count(grouped, :lesson),
        "crystal_count" => count(grouped, :crystal),
        "recall_count" => count(grouped, :recall),
        "action_count" => count(grouped, :action),
        "error_count" => Enum.count(grouped, &ObservationProjector.error?/1)
      }
    end)
  end

  defp group_key(event) do
    {
      date(event.occurred_at),
      optional_dimension(event.project),
      optional_dimension(event.agent_id),
      event.host_id,
      event.client_id,
      event.scope,
      event.namespace,
      event.event_type
    }
  end

  defp date(%DateTime{} = value), do: value |> DateTime.to_date() |> Date.to_iso8601()

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed |> DateTime.to_date() |> Date.to_iso8601()
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp optional_dimension(value) when is_binary(value), do: value
  defp optional_dimension(_value), do: ""

  defp session_count(events) do
    events
    |> Enum.map(& &1.session_id)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp count(events, kind), do: Enum.count(events, &(event_kind(&1.event_type) == kind))

  defp event_kind("memory.recalled"), do: :recall
  defp event_kind("memory." <> _suffix), do: :memory
  defp event_kind("lesson." <> _suffix), do: :lesson
  defp event_kind("crystal." <> _suffix), do: :crystal
  defp event_kind("action." <> _suffix), do: :action
  defp event_kind("task." <> _suffix), do: :action
  defp event_kind(_event_type), do: :other
end
