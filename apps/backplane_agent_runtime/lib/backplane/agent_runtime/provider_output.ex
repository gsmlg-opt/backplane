defmodule Backplane.AgentRuntime.ProviderOutput do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  @default_limit 1_048_576

  def new, do: %{parts: %{}, tools: %{}}

  def limit(opts), do: Keyword.get(opts, :provider_output_limit, tool_limit(opts))
  def tool_limit(opts), do: Keyword.get(opts, :output_limit, @default_limit)

  def validate_options(opts) do
    with :ok <- validate_limit(tool_limit(opts), :output_limit, false),
         :ok <- validate_limit(limit(opts), :provider_output_limit, true) do
      :ok
    end
  end

  def validate_limit(value, key, infinity?) do
    if (is_integer(value) and value >= 0) or (infinity? and value == :infinity),
      do: :ok,
      else:
        {:error,
         Error.new(
           :validation,
           "#{key} must be a non-negative integer#{if infinity?, do: " or :infinity", else: ""}",
           details: %{option: key}
         )}
  end

  def check(state, :infinity), do: {:ok, state}

  def check(state, limit) when is_integer(limit) and limit >= 0 do
    size =
      Enum.reduce(state.parts, 0, fn {_, part}, size -> size + max(part.delta, part.snapshot) end)

    if size <= limit,
      do: {:ok, state},
      else:
        {:error,
         Error.new(:resource_conflict, "provider output limit exceeded",
           details: %{scope: :provider_response, size: size, limit: limit}
         )}
  end

  def event(state, event) do
    # Bind tool IDs before charging deltas so index-only deltas and materialized
    # tool calls use the same logical part.
    state = message(state, Map.get(event, :message))
    index = Map.get(event, :index) || 0

    case event do
      %{type: :content_text_delta, delta: delta} when is_binary(delta) ->
        update(state, {:text, index}, :delta, byte_size(delta))

      %{type: :content_thinking_delta, delta: delta} when is_binary(delta) ->
        update(state, {:thinking, index}, :delta, byte_size(delta))

      %{type: :tool_call_arguments_delta, delta: delta} when is_binary(delta) ->
        tool_id = Map.get(event, :tool_call_id) || tool_id(Map.get(event, :tool_call))
        state = if tool_id, do: bind_tool(state, index, tool_id), else: state
        update(state, tool_key(state, index), :delta, byte_size(delta))

      %{type: type, tool_call: %{id: id} = tool}
      when type in [:tool_call_started, :tool_call_completed] ->
        state =
          if not is_nil(Map.get(event, :index)) or Map.has_key?(state.parts, {:tool_index, 0}),
            do: bind_tool(state, index, id),
            else: state

        tool(state, tool)

      _ ->
        state
    end
  end

  def response(response) do
    state = message(new(), Map.get(response, :message, response))

    response
    |> Map.get(:tool_calls, Map.get(response, :tools, []))
    |> Enum.reduce(state, &tool(&2, &1))
  end

  defp message(state, %{content: content}) when is_binary(content),
    do: update(state, {:text, 0}, :snapshot, byte_size(content))

  defp message(state, %{content: content}) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce(state, fn {block, index}, state -> block(state, block, index) end)
  end

  defp message(state, %{text: text} = response) when is_binary(text) do
    state = update(state, {:text, 0}, :snapshot, byte_size(text))
    update(state, {:thinking, 0}, :snapshot, bytes(Map.get(response, :thinking)))
  end

  defp message(state, _), do: state

  defp block(state, %{type: :text, text: text}, index),
    do: update(state, {:text, index}, :snapshot, bytes(text))

  defp block(state, %{type: type} = block, index) when type in [:thinking, :reasoning] do
    text = Map.get(block, :thinking) || Map.get(block, :text)
    update(state, {:thinking, index}, :snapshot, bytes(text))
  end

  defp block(state, %{type: :tool_call, tool_call: tool}, index) when is_map(tool),
    do: block(state, Map.put(tool, :type, :tool_call), index)

  defp block(state, %{type: :tool_call} = block, index) do
    state =
      case Map.get(block, :id) do
        id when is_binary(id) and id != "" -> state |> bind_tool(index, id) |> tool(block)
        _ -> state
      end

    update(state, tool_key(state, index), :snapshot, bytes(Map.get(block, :partial_json)))
  end

  defp block(state, _, _), do: state

  defp tool(state, %{id: id, arguments: arguments})
       when is_binary(id) and id != "" and is_binary(arguments),
       do: update(state, {:tool, id}, :snapshot, byte_size(arguments))

  defp tool(state, %{id: id, arguments: arguments})
       when is_binary(id) and id != "" and is_map(arguments),
       do: update(state, {:tool, id}, :snapshot, byte_size(JSON.encode!(arguments)))

  defp tool(state, _), do: state

  defp tool_key(state, index) do
    case Map.fetch(state.tools, index) do
      {:ok, id} -> {:tool, id}
      :error -> {:tool_index, index}
    end
  end

  defp bind_tool(state, index, id) when is_binary(id) and id != "" do
    old_key = {:tool_index, index}
    new_key = {:tool, id}
    empty = %{delta: 0, snapshot: 0}
    old = Map.get(state.parts, old_key, empty)
    current = Map.get(state.parts, new_key, empty)
    part = %{delta: max(old.delta, current.delta), snapshot: max(old.snapshot, current.snapshot)}

    %{
      state
      | tools: Map.put(state.tools, index, id),
        parts: state.parts |> Map.delete(old_key) |> Map.put(new_key, part)
    }
  end

  defp bind_tool(state, _index, _id), do: state

  defp update(state, key, kind, size) do
    part = Map.get(state.parts, key, %{delta: 0, snapshot: 0})
    value = if kind == :delta, do: part.delta + size, else: max(part.snapshot, size)
    %{state | parts: Map.put(state.parts, key, Map.put(part, kind, value))}
  end

  defp tool_id(%{id: id}), do: id
  defp tool_id(_), do: nil

  defp bytes(text) when is_binary(text), do: byte_size(text)
  defp bytes(_), do: 0
end
