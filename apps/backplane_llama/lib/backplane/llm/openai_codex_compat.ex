defmodule Backplane.LLM.OpenAICodexCompat do
  @moduledoc """
  Compatibility helpers for the OpenAI Codex preset backed by ChatGPT OAuth.

  Codex OAuth access tokens are accepted by the ChatGPT Codex backend, not by
  the public OpenAI `/v1` API. This module keeps that provider-specific routing
  and wire-format adaptation out of the generic LLM router.
  """

  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.Settings.Credentials

  @default_backend_base_url "https://chatgpt.com/backend-api/codex"

  @doc "Returns true when a provider API should use the ChatGPT Codex backend."
  @spec enabled?(Provider.t(), ProviderApi.t()) :: boolean()
  def enabled?(
        %Provider{preset_key: "openai-codex", credential: credential},
        %ProviderApi{api_surface: :openai}
      )
      when is_binary(credential) and credential != "" do
    credential_auth_type(credential) == "openai_oauth"
  end

  def enabled?(_provider, _api), do: false

  @doc "Replaces the configured public OpenAI base URL with the Codex backend."
  @spec effective_api(ProviderApi.t(), boolean()) :: ProviderApi.t()
  def effective_api(%ProviderApi{} = api, true), do: %{api | base_url: backend_base_url()}
  def effective_api(%ProviderApi{} = api, false), do: api

  @doc "Rewrite OpenAI-compatible `/v1/...` requests to backend-relative paths."
  @spec rewrite_conn_path(Plug.Conn.t(), boolean()) :: Plug.Conn.t()
  def rewrite_conn_path(%Plug.Conn{path_info: ["v1" | rest]} = conn, true) do
    put_path(conn, rest)
  end

  def rewrite_conn_path(%Plug.Conn{} = conn, _codex_backend?), do: conn

  @doc "Routes an OpenAI Chat Completions compatibility request to Responses."
  @spec responses_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def responses_conn(%Plug.Conn{} = conn), do: put_path(conn, ["responses"])

  @doc "Returns true for the OpenAI Chat Completions route."
  @spec chat_completions_request?(Plug.Conn.t()) :: boolean()
  def chat_completions_request?(%Plug.Conn{path_info: ["v1", "chat", "completions"]}), do: true
  def chat_completions_request?(_conn), do: false

  @doc "Convert an OpenAI Chat Completions request body into a Responses body."
  @spec chat_completions_to_responses_body(binary()) :: {:ok, binary()} | {:error, atom()}
  def chat_completions_to_responses_body(body) when is_binary(body) do
    with {:ok, %{} = chat} <- Jason.decode(body),
         {:ok, responses} <- build_responses_request(chat),
         {:ok, encoded} <- Jason.encode(responses) do
      {:ok, encoded}
    else
      {:ok, _} -> {:error, :invalid_json}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  @doc "Convert a non-streaming Responses body into Chat Completions shape."
  @spec response_body_to_chat_completion(binary(), String.t()) :: binary()
  def response_body_to_chat_completion(body, model) when is_binary(body) do
    with {:ok, %{} = response} <- Jason.decode(body),
         false <- is_map(response["error"]) do
      response
      |> chat_completion_response(model)
      |> Jason.encode!()
    else
      _ -> body
    end
  end

  @doc """
  Build a stateful chunk mapper that converts Responses SSE into Chat SSE.

  Returns `{mapper, cleanup}`. `mapper.(chunk)` returns the list of downstream
  chunks that should be forwarded for the given upstream chunk.
  """
  @spec chat_completion_stream_mapper(String.t()) :: {function(), function()}
  def chat_completion_stream_mapper(model) do
    {:ok, pid} = Agent.start_link(fn -> new_stream_state(model) end)

    mapper = fn chunk ->
      Agent.get_and_update(pid, fn state ->
        {mapped, next_state} = map_response_stream_chunk(chunk, state)
        {mapped, next_state}
      end)
    end

    cleanup = fn ->
      if Process.alive?(pid) do
        Agent.stop(pid, :normal, 1_000)
      end
    end

    {mapper, cleanup}
  end

  defp backend_base_url do
    Application.get_env(:backplane, :openai_codex_backend_base_url, @default_backend_base_url)
  end

  defp credential_auth_type(name) do
    Credentials.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      cred -> credential_metadata_auth_type(cred.metadata)
    end
  end

  defp credential_metadata_auth_type(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_metadata_auth_type(_metadata), do: "api_key"

  defp put_path(conn, path_info) do
    %{conn | path_info: path_info, request_path: "/" <> Enum.join(path_info, "/")}
  end

  defp build_responses_request(%{"model" => model} = chat) when is_binary(model) do
    {input, instructions} = messages_to_responses_input(chat["messages"] || [])
    tools = tools_to_responses(chat["tools"] || [])

    responses =
      %{
        "model" => model,
        "stream" => chat["stream"] == true,
        "store" => false,
        "input" => input,
        "parallel_tool_calls" => Map.get(chat, "parallel_tool_calls", true)
      }
      |> put_if_present("instructions", instructions)
      |> put_if_present("tools", empty_to_nil(tools))
      |> put_if_present("tool_choice", tool_choice_to_responses(chat["tool_choice"]))
      |> put_if_present("reasoning", reasoning_to_responses(chat))

    {:ok, responses}
  end

  defp build_responses_request(_chat), do: {:error, :no_model}

  defp messages_to_responses_input(messages) when is_list(messages) do
    Enum.reduce(messages, {[], []}, fn message, {input, instructions} ->
      case message_to_responses_item(message) do
        {:instruction, text} -> {input, [text | instructions]}
        {:items, items} -> {input ++ items, instructions}
        :ignore -> {input, instructions}
      end
    end)
    |> then(fn {input, instructions} ->
      instruction_text =
        instructions
        |> Enum.reverse()
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> nil
          parts -> Enum.join(parts, "\n\n")
        end

      {input, instruction_text}
    end)
  end

  defp messages_to_responses_input(_messages), do: {[], nil}

  defp message_to_responses_item(%{"role" => role} = message)
       when role in ["system", "developer"] do
    {:instruction, text_from_content(message["content"])}
  end

  defp message_to_responses_item(%{"role" => "tool"} = message) do
    case message["tool_call_id"] do
      call_id when is_binary(call_id) ->
        {:items,
         [
           %{
             "type" => "function_call_output",
             "call_id" => call_id,
             "output" => text_from_content(message["content"])
           }
         ]}

      _ ->
        :ignore
    end
  end

  defp message_to_responses_item(%{"role" => "assistant"} = message) do
    content = text_from_content(message["content"])

    message_items =
      if content == "" do
        []
      else
        [%{"role" => "assistant", "content" => content}]
      end

    tool_call_items =
      message
      |> Map.get("tool_calls", [])
      |> Enum.flat_map(&tool_call_to_responses_item/1)

    {:items, message_items ++ tool_call_items}
  end

  defp message_to_responses_item(%{"role" => "user"} = message) do
    {:items, [%{"role" => "user", "content" => user_content_to_responses(message["content"])}]}
  end

  defp message_to_responses_item(_message), do: :ignore

  defp tool_call_to_responses_item(%{"id" => id, "function" => %{"name" => name} = function})
       when is_binary(id) and is_binary(name) do
    [
      %{
        "type" => "function_call",
        "call_id" => id,
        "name" => name,
        "arguments" => function["arguments"] || "{}"
      }
    ]
  end

  defp tool_call_to_responses_item(_tool_call), do: []

  defp user_content_to_responses(content) when is_binary(content), do: content

  defp user_content_to_responses(content) when is_list(content) do
    parts =
      content
      |> Enum.flat_map(&content_part_to_responses/1)

    if parts == [], do: text_from_content(content), else: parts
  end

  defp user_content_to_responses(content), do: text_from_content(content)

  defp content_part_to_responses(%{"type" => "text", "text" => text}) when is_binary(text) do
    [%{"type" => "input_text", "text" => text}]
  end

  defp content_part_to_responses(%{"type" => "image_url", "image_url" => %{"url" => url}})
       when is_binary(url) do
    [%{"type" => "input_image", "image_url" => url}]
  end

  defp content_part_to_responses(_part), do: []

  defp text_from_content(content) when is_binary(content), do: content

  defp text_from_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_from_content(nil), do: ""
  defp text_from_content(content), do: inspect(content)

  defp tools_to_responses(tools) when is_list(tools),
    do: Enum.flat_map(tools, &tool_to_responses/1)

  defp tools_to_responses(_tools), do: []

  defp tool_to_responses(%{"function" => %{"name" => name} = function}) when is_binary(name) do
    [
      %{
        "type" => "function",
        "name" => name,
        "description" => function["description"] || "",
        "parameters" => function["parameters"] || %{"type" => "object", "properties" => %{}},
        "strict" => false
      }
    ]
  end

  defp tool_to_responses(_tool), do: []

  defp tool_choice_to_responses(nil), do: nil
  defp tool_choice_to_responses("none"), do: nil
  defp tool_choice_to_responses("auto"), do: "auto"
  defp tool_choice_to_responses("required"), do: "required"

  defp tool_choice_to_responses(%{"type" => "function", "function" => %{"name" => name}})
       when is_binary(name) do
    %{"type" => "function", "name" => name}
  end

  defp tool_choice_to_responses(choice), do: choice

  defp reasoning_to_responses(%{"reasoning_effort" => effort}) when is_binary(effort) do
    %{"effort" => effort}
  end

  defp reasoning_to_responses(_chat), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

  defp chat_completion_response(response, model) do
    text = response["output_text"] || output_text(response["output"])
    usage = response["usage"] || %{}

    %{
      "id" => response["id"] || chat_id(),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"] || model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => finish_reason(response)
        }
      ],
      "usage" => chat_usage(usage)
    }
  end

  defp output_text(output) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) -> content
      _ -> []
    end)
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp output_text(_output), do: ""

  defp finish_reason(%{"status" => "incomplete"}), do: "length"
  defp finish_reason(_response), do: "stop"

  defp new_stream_state(model) do
    %{
      buffer: "",
      id: chat_id(),
      created: System.system_time(:second),
      model: model,
      sent_role?: false,
      done?: false
    }
  end

  defp map_response_stream_chunk(chunk, state) do
    buffer = String.replace(state.buffer <> chunk, "\r\n", "\n")
    {frames, rest} = split_sse_frames(buffer)
    state = %{state | buffer: rest}

    Enum.map_reduce(frames, state, fn frame, acc ->
      case parse_sse_frame(frame) do
        {:ok, event} -> map_response_event(event, acc)
        :done -> finish_stream(acc, "stop", %{})
        :ignore -> {[], acc}
      end
    end)
    |> then(fn {chunks, next_state} -> {List.flatten(chunks), next_state} end)
  end

  defp split_sse_frames(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [partial] -> {[], partial}
      _ -> {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp parse_sse_frame(frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          ["data", value] -> [String.trim_leading(value)]
          _ -> []
        end
      end)
      |> Enum.join("\n")

    cond do
      data == "" ->
        :ignore

      data == "[DONE]" ->
        :done

      true ->
        case Jason.decode(data) do
          {:ok, event} -> {:ok, event}
          {:error, _reason} -> :ignore
        end
    end
  end

  defp map_response_event(%{"type" => "response.output_text.delta", "delta" => delta}, state)
       when is_binary(delta) do
    {ensure_role(state) ++ [chat_delta(state, %{"content" => delta})],
     %{state | sent_role?: true}}
  end

  defp map_response_event(%{"type" => "response.reasoning_text.delta", "delta" => delta}, state)
       when is_binary(delta) do
    {ensure_role(state) ++ [chat_delta(state, %{"reasoning_content" => delta})],
     %{state | sent_role?: true}}
  end

  defp map_response_event(
         %{
           "type" => "response.output_item.added",
           "output_index" => output_index,
           "item" => %{"type" => "function_call", "name" => name} = item
         },
         state
       )
       when is_integer(output_index) and is_binary(name) do
    call_id = item["call_id"] || item["id"] || "call_#{output_index}"

    delta = %{
      "tool_calls" => [
        %{
          "index" => output_index,
          "id" => call_id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => ""}
        }
      ]
    }

    {ensure_role(state) ++ [chat_delta(state, delta)], %{state | sent_role?: true}}
  end

  defp map_response_event(
         %{
           "type" => "response.function_call_arguments.delta",
           "output_index" => output_index,
           "delta" => delta
         },
         state
       )
       when is_integer(output_index) and is_binary(delta) do
    {[
       chat_delta(state, %{
         "tool_calls" => [%{"index" => output_index, "function" => %{"arguments" => delta}}]
       })
     ], state}
  end

  defp map_response_event(%{"type" => "response.completed"} = event, state) do
    usage = get_in(event, ["response", "usage"]) || event["usage"] || %{}
    finish_stream(state, "stop", usage)
  end

  defp map_response_event(%{"type" => "response.incomplete"} = event, state) do
    usage = get_in(event, ["response", "usage"]) || event["usage"] || %{}
    finish_stream(state, "length", usage)
  end

  defp map_response_event(_event, state), do: {[], state}

  defp ensure_role(%{sent_role?: true}), do: []
  defp ensure_role(state), do: [chat_delta(state, %{"role" => "assistant"})]

  defp finish_stream(%{done?: true} = state, _reason, _usage), do: {[], state}

  defp finish_stream(state, reason, usage) do
    final =
      state
      |> chat_finish(reason, usage)

    {[final, "data: [DONE]\n\n"], %{state | done?: true, sent_role?: true}}
  end

  defp chat_delta(state, delta) do
    %{
      "id" => state.id,
      "object" => "chat.completion.chunk",
      "created" => state.created,
      "model" => state.model,
      "choices" => [
        %{"index" => 0, "delta" => delta, "finish_reason" => nil}
      ]
    }
    |> sse_json()
  end

  defp chat_finish(state, reason, usage) do
    %{
      "id" => state.id,
      "object" => "chat.completion.chunk",
      "created" => state.created,
      "model" => state.model,
      "choices" => [
        %{"index" => 0, "delta" => %{}, "finish_reason" => reason}
      ],
      "usage" => chat_usage(usage)
    }
    |> sse_json()
  end

  defp chat_usage(usage) when is_map(usage) do
    input = integer_or_zero(usage["input_tokens"])
    output = integer_or_zero(usage["output_tokens"])

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => total_tokens(usage, input, output)
    }
  end

  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_value), do: 0

  defp total_tokens(%{"total_tokens" => total}, _input, _output) when is_integer(total), do: total
  defp total_tokens(_usage, input, output), do: input + output

  defp sse_json(data), do: "data: #{Jason.encode!(data)}\n\n"

  defp chat_id do
    "chatcmpl-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
