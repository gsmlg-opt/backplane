defmodule Backplane.LLM.ModelResponse.StreamMapper do
  @moduledoc """
  Bounded, request-local, protocol-aware SSE stream mapper for alias model restoration.

  Implements Relayixir's `:response_stream_mapper` contract (`init/3`, `feed/2`,
  `finish/2`). Rewrites only the response model fields defined by the selected
  protocol when they match `resolved_model`, leaving all other bytes, comments,
  CRLF line endings, unknown fields, and nested tool/output properties untouched.
  """

  alias Backplane.LLM.ModelResponse

  @default_max_line_bytes 1_048_576
  @default_max_json_bytes 8_388_608

  @type protocol :: :openai_chat_completions | :openai_responses | :anthropic_messages

  @spec init(integer(), [{String.t(), String.t()}], map()) :: {:ok, map()}
  def init(status, headers, %{
        protocol: protocol,
        requested_model: requested,
        resolved_model: resolved
      } = opts)
      when is_binary(requested) and is_binary(resolved) do
    max_line_bytes = Map.get(opts, :max_line_bytes, @default_max_line_bytes)
    max_json_bytes = Map.get(opts, :max_json_bytes, @default_max_json_bytes)
    encoding = header_value(headers, "content-encoding")
    content_type = header_value(headers, "content-type") || ""

    cond do
      requested == resolved or status not in 200..299 ->
        {:ok, %{mode: :passthrough}}

      encoding not in [nil, "", "identity"] ->
        {:ok, %{mode: :passthrough}}

      sse_content_type?(content_type) ->
        {:ok,
         %{
           mode: :sse,
           protocol: protocol,
           requested: requested,
           resolved: resolved,
           buffer: "",
           passthrough_line?: false,
           max_line_bytes: max_line_bytes
         }}

      json_content_type?(content_type) ->
        {:ok,
         %{
           mode: :json,
           protocol: protocol,
           requested: requested,
           resolved: resolved,
           buffer: "",
           max_json_bytes: max_json_bytes
         }}

      true ->
        {:ok, %{mode: :passthrough}}
    end
  end

  def init(_status, _headers, _opts), do: {:ok, %{mode: :passthrough}}

  @spec feed(map(), binary()) :: {:ok, map(), [binary()]}
  def feed(%{mode: :passthrough} = state, chunk) when is_binary(chunk) do
    {:ok, state, [chunk]}
  end

  def feed(%{mode: :json} = state, chunk) when is_binary(chunk) do
    next = state.buffer <> chunk

    if byte_size(next) > state.max_json_bytes do
      {:ok, %{mode: :passthrough}, [next]}
    else
      {:ok, %{state | buffer: next}, []}
    end
  end

  def feed(%{mode: :sse} = state, ""), do: {:ok, state, []}

  def feed(%{mode: :sse} = state, chunk) when is_binary(chunk) do
    {emitted, buffer, passthrough_line?} =
      consume_lines(
        state.buffer <> chunk,
        state.passthrough_line?,
        state.protocol,
        state.requested,
        state.resolved,
        state.max_line_bytes,
        []
      )

    {:ok, %{state | buffer: buffer, passthrough_line?: passthrough_line?}, emitted}
  end

  @spec finish(map(), term()) :: {:ok, map(), [binary()]}
  def finish(%{mode: :passthrough} = state, _reason), do: {:ok, state, []}

  def finish(%{mode: :json, buffer: ""} = state, _reason), do: {:ok, state, []}

  def finish(%{mode: :json} = state, :eof) do
    body = ModelResponse.normalize_body_for_protocol(state.buffer, state.protocol, state.requested, state.resolved)
    {:ok, %{state | buffer: ""}, [body]}
  end

  def finish(%{mode: :json} = state, :cancelled), do: {:ok, %{state | buffer: ""}, []}

  def finish(%{mode: :json} = state, _reason) do
    {:ok, %{state | buffer: ""}, [state.buffer]}
  end

  def finish(%{mode: :sse, buffer: ""} = state, _reason), do: {:ok, state, []}

  def finish(%{mode: :sse} = state, :cancelled) do
    {:ok, %{state | buffer: "", passthrough_line?: false}, []}
  end

  def finish(%{mode: :sse, passthrough_line?: true} = state, _reason) do
    {:ok, %{state | buffer: "", passthrough_line?: false}, [state.buffer]}
  end

  def finish(%{mode: :sse} = state, :eof) do
    tail =
      ModelResponse.normalize_sse_line(
        state.buffer,
        state.protocol,
        state.requested,
        state.resolved
      )

    {:ok, %{state | buffer: "", passthrough_line?: false}, [tail]}
  end

  def finish(%{mode: :sse} = state, _reason) do
    # Flush raw trailing bytes on transport error without inventing completion.
    {:ok, %{state | buffer: "", passthrough_line?: false}, [state.buffer]}
  end

  defp consume_lines(data, passthrough_line?, protocol, requested, resolved, max_line_bytes, acc) do
    case :binary.match(data, "\n") do
      {newline, 1} ->
        line = binary_part(data, 0, newline + 1)
        rest = binary_part(data, newline + 1, byte_size(data) - newline - 1)

        mapped =
          if passthrough_line? do
            line
          else
            ModelResponse.normalize_sse_line(line, protocol, requested, resolved)
          end

        consume_lines(rest, false, protocol, requested, resolved, max_line_bytes, [mapped | acc])

      :nomatch when byte_size(data) > max_line_bytes ->
        {Enum.reverse([data | acc]), "", true}

      :nomatch ->
        {Enum.reverse(acc), data, passthrough_line?}
    end
  end

  defp sse_content_type?(content_type) do
    content_type |> String.downcase() |> String.starts_with?("text/event-stream")
  end

  defp json_content_type?(content_type) do
    down = String.downcase(content_type)
    String.starts_with?(down, "application/json") or String.contains?(down, "+json")
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {header_name, value} ->
      if String.downcase(header_name) == name, do: String.trim(value)
    end)
  end
end
