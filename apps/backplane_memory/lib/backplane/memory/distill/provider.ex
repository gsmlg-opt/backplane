defmodule Backplane.Memory.Distill.Provider do
  @moduledoc """
  Agent-runtime provider adapter backed by `Backplane.Memory.LLM.ChatClient`.

  Converts canonical runtime history to chat-completions messages, performs one
  non-streaming completion and returns normalized events. Assistant tool calls
  are carried as `:tool_call` content blocks on the completed message, so the
  runtime stores them in history and they convert back into `tool_calls` on the
  next request.

  Context keys: `:chat_client` (module, default `ChatClient`) and `:chat_opts`
  (keyword passed to `complete/3`).
  """

  @behaviour Backplane.AgentRuntime.ConversationAdapter

  alias Backplane.AgentRuntime.Error
  alias Backplane.Memory.LLM.ChatClient

  @impl true
  def stream(request, context) do
    client = Map.get(context, :chat_client, ChatClient)
    opts = Map.get(context, :chat_opts, [])
    messages = Enum.map(Map.get(request, :messages, []), &to_chat/1)

    case client.complete(messages, Map.get(request, :tools, []), opts) do
      {:ok, response} -> completed_events(response)
      {:error, error} -> [%{type: :response_started}, %{type: :response_failed, error: error}]
    end
  end

  defp completed_events(%{content: content, tool_calls: calls} = response) do
    usage = normalize_usage(Map.get(response, :usage))

    [%{type: :response_started}] ++
      Enum.map(calls, &%{type: :tool_call_completed, tool_call: &1}) ++
      if(usage, do: [%{type: :usage_updated, usage: usage}], else: []) ++
      [
        %{
          type: :response_completed,
          message: %{role: :assistant, content: message_content(content, calls)}
        }
      ]
  end

  defp message_content(content, []), do: content || ""

  defp message_content(content, calls) do
    text = if is_binary(content) and content != "", do: [%{type: :text, text: content}], else: []
    text ++ Enum.map(calls, &Map.put(&1, :type, :tool_call))
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: count(usage["prompt_tokens"]),
      cached_tokens: count(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
      output_tokens: count(usage["completion_tokens"]),
      reasoning_tokens: count(get_in(usage, ["completion_tokens_details", "reasoning_tokens"]))
    }
  end

  defp normalize_usage(_), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  # -- runtime history -> chat-completions messages --------------------------

  defp to_chat(%{role: role} = message), do: to_chat(to_string(role), message)

  defp to_chat("assistant", message) do
    blocks = blocks(Map.get(message, :content))
    calls = for %{type: :tool_call} = block <- blocks, do: chat_tool_call(block)
    text = text(blocks)

    base = %{
      "role" => "assistant",
      "content" => if(calls != [] and text == "", do: nil, else: text)
    }

    if calls == [], do: base, else: Map.put(base, "tool_calls", calls)
  end

  defp to_chat("tool", message) do
    %{
      "role" => "tool",
      "tool_call_id" => Map.get(message, :tool_call_id),
      "content" => tool_result_text(Map.get(message, :result))
    }
  end

  defp to_chat(role, message),
    do: %{"role" => role, "content" => text(blocks(Map.get(message, :content)))}

  defp blocks(content) when is_binary(content), do: [%{type: :text, text: content}]
  defp blocks(content) when is_list(content), do: Enum.map(content, &block/1)
  defp blocks(_), do: []

  defp block(%{type: :tool_call, tool_call: call}) when is_map(call),
    do: Map.put(call, :type, :tool_call)

  defp block(block) when is_map(block), do: block
  defp block(text) when is_binary(text), do: %{type: :text, text: text}
  defp block(_), do: %{}

  defp text(blocks) do
    Enum.map_join(blocks, "", fn
      %{type: :text, text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp chat_tool_call(%{id: id, name: name} = call) do
    arguments =
      case Map.get(call, :arguments) do
        args when is_binary(args) -> args
        args when is_map(args) -> Jason.encode!(args)
        _ -> "{}"
      end

    %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_result_text(%{is_error: true} = result),
    do: encode(%{"error" => error_map(Map.get(result, :error))})

  defp tool_result_text(%{content: content}) when is_binary(content), do: content

  defp tool_result_text(%{content: content}) when is_list(content) do
    if Enum.all?(content, &match?(%{type: :text}, &1)),
      do: text(content),
      else: encode(content)
  end

  defp tool_result_text(result), do: encode(result)

  defp error_map(%Error{} = error), do: Error.to_map(error)
  defp error_map(error) when is_binary(error), do: %{"message" => error}
  defp error_map(error), do: %{"message" => inspect(error)}

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
