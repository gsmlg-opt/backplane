defmodule Backplane.Memory.Projections.ObservationProjector do
  @moduledoc "Pure deterministic captured-event to observation projection."

  alias Backplane.Memory.Projections.{EventOrder, Revision}

  def project(events) when is_list(events) do
    ordered = EventOrder.sort(events)
    first = List.first(ordered)

    %{
      "host_id" => field(first, :host_id),
      "client_id" => field(first, :client_id),
      "scope" => field(first, :scope),
      "namespace" => field(first, :namespace),
      "session_id" => field(first, :session_id),
      "project" => first_value(ordered, :project),
      "agent_id" => first_value(ordered, :agent_id),
      "observations" => Enum.map(ordered, &observation/1)
    }
  end

  defp observation(event) do
    source = source(event)
    message = message(event, source)

    %{
      "event_id" => event.id,
      "project" => event.project,
      "agent_id" => event.agent_id,
      "source_sequence" => event.source_sequence,
      "event_type" => event.event_type,
      "occurred_at" => iso8601(event.occurred_at),
      "content" => message,
      "message" => message,
      "tool_name" => tool_name(event),
      "importance" => event.importance,
      "is_error" => error?(event),
      "file_paths" => file_paths(event.payload),
      "commit_hash" => binary_value(source, "commit_hash")
    }
  end

  defp message(event, source) do
    [
      event.content,
      binary_value(source, "message"),
      binary_value(source, "prompt"),
      binary_value(source, "error"),
      content_value(source, "tool_response"),
      content_value(source, "result"),
      binary_value(source, "commit_message"),
      binary_value(event.payload, "message"),
      binary_value(event.payload, "content"),
      binary_value(source, "reason")
    ]
    |> Enum.find(&non_empty_binary?/1)
    |> case do
      nil -> event.event_type
      value -> value
    end
  end

  def tool_name(event) do
    if non_empty_binary?(event.tool_name),
      do: event.tool_name,
      else: binary_value(source(event), "tool_name")
  end

  def error?(event) do
    event.event_type in ["agent.tool.failed", "tool.call.failed", "agent.run.failed"] or
      event.status == "failed" or get_in(source(event), ["is_error"]) == true
  end

  defp source(event) do
    case event.payload do
      %{"source" => source} when is_map(source) -> source
      _ -> %{}
    end
  end

  defp file_paths(value) do
    value
    |> collect_file_paths([])
    |> Enum.filter(&non_empty_binary?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_file_paths(map, paths) when is_map(map) do
    Enum.reduce(map, paths, fn {key, value}, acc ->
      acc =
        if key in ["file_path", "path", "files", "file_paths", "paths"],
          do: collect_path_value(value, acc),
          else: acc

      collect_file_paths(value, acc)
    end)
  end

  defp collect_file_paths([head | tail], paths),
    do: collect_file_paths(tail, collect_file_paths(head, paths))

  defp collect_file_paths([], paths), do: paths
  defp collect_file_paths(_value, paths), do: paths

  defp collect_path_value(value, paths) when is_binary(value), do: [value | paths]

  defp collect_path_value(values, paths) when is_list(values) do
    Enum.reduce(values, paths, fn
      value, acc when is_binary(value) -> [value | acc]
      _value, acc -> acc
    end)
  end

  defp collect_path_value(_value, paths), do: paths

  defp field(nil, _field), do: nil
  defp field(event, field), do: Map.get(event, field)

  defp first_value(events, field) do
    Enum.find_value(events, fn event ->
      case Map.get(event, field) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        _value -> nil
      end
    end)
  end

  defp binary_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp binary_value(_value, _key), do: nil

  defp content_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      value when is_map(value) or is_list(value) -> encode_json(value)
      _value -> nil
    end
  end

  defp encode_json(value) do
    case Revision.encode_json(value) do
      {:ok, encoded} -> encoded
      {:error, :not_json_safe} -> nil
    end
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
end
