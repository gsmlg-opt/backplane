defmodule Backplane.Memory.LLM.ChatClient do
  @moduledoc """
  Non-streaming OpenAI chat-completions client for the memory agent.

  Requests go through the Backplane LLM proxy with tool calling enabled. Every
  failure is returned as a readable string naming the model where one is known.
  """

  alias Backplane.Memory.Config

  @default_receive_timeout 120_000
  @body_preview_chars 300

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type result :: %{content: String.t() | nil, tool_calls: [tool_call()], usage: map() | nil}

  @spec complete([map()], [map()], keyword()) :: {:ok, result()} | {:error, String.t()}
  def complete(messages, tools, opts \\ []) when is_list(messages) and is_list(tools) do
    case model(opts) do
      nil -> {:error, "memory.llm_model not configured"}
      model -> do_complete(messages, tools, model, opts)
    end
  end

  defp model(opts) do
    case Keyword.get(opts, :model) || Config.llm_model() do
      model when is_binary(model) -> if String.trim(model) == "", do: nil, else: model
      _ -> nil
    end
  end

  defp do_complete(messages, tools, model, opts) do
    base_url = Application.fetch_env!(:backplane_memory, :llm_proxy_url)

    request_opts =
      [
        url: base_url <> "/v1/chat/completions",
        headers: [
          {"x-backplane-memory-origin", "agent"},
          {"x-backplane-memory-capture", "skip"}
        ],
        json: %{
          model: model,
          messages: messages,
          tools: Enum.map(tools, &openai_tool/1),
          tool_choice: "auto",
          stream: false
        },
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
        retry: false
      ] ++ Keyword.get(opts, :http_options, [])

    case Backplane.Memory.ProxyAuth.authorize(request_opts) do
      {:ok, request_opts} -> request(request_opts, model)
      {:error, _} -> {:error, "proxy credential unavailable"}
    end
  end

  defp openai_tool(tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: Map.get(tool, :description, ""),
        parameters: Map.get(tool, :parameters, %{"type" => "object"})
      }
    }
  end

  defp request(request_opts, model) do
    case Backplane.HTTPClient.post(request_opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => message} | _]} = body}}
      when is_map(message) ->
        with {:ok, calls} <- tool_calls(message["tool_calls"], model) do
          {:ok,
           %{content: content(message["content"]), tool_calls: calls, usage: usage(body["usage"])}}
        end

      {:ok, %{status: 200}} ->
        {:error, "LLM response for model #{model} had no choices"}

      {:ok, %{status: status, body: body}} ->
        {:error, "LLM proxy returned HTTP #{status} for model #{model}: #{preview(body)}"}

      {:error, reason} ->
        {:error, "LLM proxy unreachable: #{reason_text(reason)}"}
    end
  end

  defp content(text) when is_binary(text), do: text
  defp content(_), do: nil

  defp tool_calls(nil, _model), do: {:ok, []}

  defp tool_calls(calls, model) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn
      %{"id" => id, "function" => %{"name" => name} = function}, {:ok, acc}
      when is_binary(id) and id != "" and is_binary(name) and name != "" ->
        call = %{id: id, name: name, arguments: decode_arguments(function["arguments"])}
        {:cont, {:ok, acc ++ [call]}}

      _malformed, _acc ->
        {:halt, {:error, "LLM response for model #{model} had a malformed tool call"}}
    end)
  end

  defp tool_calls(_calls, model),
    do: {:error, "LLM response for model #{model} had a malformed tool call"}

  defp decode_arguments(nil), do: %{}
  defp decode_arguments(""), do: %{}
  defp decode_arguments(args) when is_map(args), do: args

  defp decode_arguments(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, args} when is_map(args) -> args
      _ -> %{"_invalid_json" => raw}
    end
  end

  defp decode_arguments(raw), do: %{"_invalid_json" => inspect(raw)}

  defp usage(usage) when is_map(usage), do: usage
  defp usage(_), do: nil

  defp preview(body) when is_binary(body), do: String.slice(body, 0, @body_preview_chars)

  defp preview(body) do
    case Jason.encode(body) do
      {:ok, json} -> preview(json)
      _ -> preview(inspect(body))
    end
  end

  # Keep transport failures readable ("connection refused"), not an inspected atom.
  defp reason_text(%Backplane.HTTPClient.Error{reason: reason}) when is_atom(reason) do
    case :inet.format_error(reason) do
      ~c"unknown POSIX error" -> inspect(reason)
      message -> List.to_string(message)
    end
  end

  defp reason_text(exception), do: Exception.message(exception)
end
