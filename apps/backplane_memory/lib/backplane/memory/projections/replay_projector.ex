defmodule Backplane.Memory.Projections.ReplayProjector do
  @moduledoc "Pure canonical-event replay projection independent of source integration."

  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Projections.EventOrder

  def project(events) when is_list(events) do
    events
    |> EventOrder.sort()
    |> Enum.flat_map(fn event ->
      Enum.map(kinds(event.event_type), &project_event(event, &1))
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, position} -> Map.put(row, "position", position) end)
  end

  defp project_event(event, kind) do
    source = if is_map(event.payload["source"]), do: event.payload["source"], else: %{}

    detail =
      %{
        "content" =>
          first_value([
            event.content,
            source["message"],
            source["prompt"],
            source["error"],
            source["commit_message"],
            event.payload["message"],
            event.payload["content"]
          ]),
        "tool_input" => first_value([source["tool_input"], source["input"]]),
        "tool_output" => first_value([source["tool_response"], source["result"]]),
        "tool_name" => first_string([event.tool_name, source["tool_name"]]),
        "status" => event.status,
        "commit_hash" => source["commit_hash"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new(fn {key, value} -> {key, filter(value)} end)

    %{
      "event_id" => event.id,
      "source_sequence" => event.source_sequence,
      "kind" => kind,
      "event_type" => event.event_type,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "detail" => detail
    }
  end

  defp kinds(type) when type in ["conversation.user_message", "agent.prompt.submitted"],
    do: ["prompt"]

  defp kinds("conversation.agent_message"), do: ["assistant_response"]

  defp kinds(type) when type in ["agent.subagent.started", "agent.subagent.stopped"],
    do: ["subagent_lifecycle"]

  defp kinds("tool.call.started"), do: ["agent_tool_call"]

  defp kinds(type) when type in ["tool.call.completed", "agent.tool.completed"],
    do: ["agent_tool_result"]

  defp kinds(type) when type in ["tool.call.failed", "agent.tool.failed"], do: ["error"]
  defp kinds("agent.run.failed"), do: ["error", "session_boundary"]

  defp kinds("git.commit.created"), do: ["commit"]

  defp kinds(type)
       when type in [
              "session.started",
              "session.ended",
              "agent.session.started",
              "agent.session.stopped",
              "agent.session.ended",
              "agent.session.abandoned",
              "agent.run.started",
              "agent.run.completed"
            ],
       do: ["session_boundary"]

  defp kinds(_type), do: []

  defp first_string(values), do: Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp first_value(values) do
    Enum.find_value(values, fn
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      value when is_map(value) or is_list(value) -> value
      _value -> nil
    end)
  end

  defp filter(value) when is_binary(value) do
    {:ok, filtered} = Filter.apply_bounded(value, 65_536)
    filtered
  end

  defp filter(value) when is_map(value) or is_list(value) do
    {:ok, %{"value" => filtered}} = Filter.apply_payload(%{"value" => value})
    bound_strings(filtered)
  end

  defp filter(value), do: value

  defp bound_strings(value) when is_binary(value), do: filter(value)

  defp bound_strings(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, bound_strings(item)} end)

  defp bound_strings(value) when is_list(value), do: Enum.map(value, &bound_strings/1)
  defp bound_strings(value), do: value
end
