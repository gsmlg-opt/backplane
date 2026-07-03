defmodule Backplane.Proxy.SSEParser do
  @moduledoc """
  Pure W3C Server-Sent Events frame parser.

  Stateless — accepts a binary chunk and a buffer, returns parsed events
  and the remaining unparsed buffer. Handles `\\r\\n`, `\\r`, and `\\n` line
  endings, multi-line `data:` fields, comment lines, and all standard SSE
  fields (`event`, `data`, `id`, `retry`).

  Events with no `data:` lines are silently dropped per the W3C spec.
  """

  @type t :: %__MODULE__{
          event: String.t(),
          data: String.t() | nil,
          id: String.t() | nil,
          retry: non_neg_integer() | nil
        }

  defstruct event: "message", data: nil, id: nil, retry: nil

  @doc """
  Parse an SSE chunk, returning completed events and the remaining buffer.

  ## Parameters

    * `chunk` — the new binary data received from the stream
    * `buffer` — leftover bytes from the previous call (default `""`)

  ## Returns

    `{[%SSEParser{}], rest}` where `rest` is the unconsumed buffer.
  """
  @spec parse(chunk :: binary(), buffer :: binary()) :: {[t()], rest :: binary()}
  def parse(chunk, buffer \\ "") do
    input =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    {frames, rest} = split_complete_frames(input)

    events =
      frames
      |> Enum.map(&parse_frame/1)
      |> Enum.reject(&is_nil/1)

    {events, rest}
  end

  defp split_complete_frames(buffer) do
    parts = String.split(buffer, "\n\n")

    case String.ends_with?(buffer, "\n\n") do
      true -> {Enum.reject(parts, &(&1 == "")), ""}
      false -> {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp parse_frame(frame) do
    parsed =
      frame
      |> String.split("\n")
      |> Enum.reduce(%{event: "message", data: [], id: nil, retry: nil}, &parse_line/2)

    case parsed.data do
      [] ->
        nil

      data ->
        %__MODULE__{
          event: parsed.event,
          data: data |> Enum.reverse() |> Enum.join("\n"),
          id: parsed.id,
          retry: parsed.retry
        }
    end
  end

  defp parse_line(":" <> _comment, event), do: event
  defp parse_line("", event), do: event

  defp parse_line(line, event) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> apply_field(field, strip_leading_space(value), event)
      [_field_without_value] -> event
    end
  end

  defp strip_leading_space(" " <> value), do: value
  defp strip_leading_space(value), do: value

  defp apply_field("event", value, event), do: %{event | event: value}
  defp apply_field("data", value, event), do: %{event | data: [value | event.data]}
  defp apply_field("id", value, event), do: %{event | id: value}

  defp apply_field("retry", value, event) do
    case Integer.parse(value) do
      {retry, ""} -> %{event | retry: retry}
      _other -> event
    end
  end

  defp apply_field(_field, _value, event), do: event
end
