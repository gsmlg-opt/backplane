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
    input = buffer <> chunk

    # Normalize line endings: \r\n -> \n, then bare \r -> \n
    normalized = input |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    # Split on double-newline (event boundary). The last segment may be
    # an incomplete event (no trailing \n\n yet).
    case String.split(normalized, "\n\n", trim: false) do
      [incomplete] ->
        # No complete event found
        {[], incomplete}

      segments ->
        # Everything except the last segment is a complete event block.
        # The last segment is the leftover buffer.
        {blocks, [rest]} = Enum.split(segments, length(segments) - 1)

        events =
          blocks
          |> Enum.map(&parse_block/1)
          |> Enum.reject(&is_nil/1)

        {events, rest}
    end
  end

  # Parse a single event block (the text between two \n\n boundaries).
  # Returns nil when the block has no data lines (per W3C spec, such
  # events are not dispatched).
  defp parse_block(block) do
    lines = String.split(block, "\n")

    acc = %{event: "message", data: [], id: nil, retry: nil}

    result =
      Enum.reduce(lines, acc, fn line, acc ->
        parse_line(line, acc)
      end)

    if result.data == [] do
      nil
    else
      data = result.data |> Enum.reverse() |> Enum.join("\n")

      %__MODULE__{
        event: result.event,
        data: data,
        id: result.id,
        retry: result.retry
      }
    end
  end

  # Comment line — starts with ":"
  defp parse_line(":" <> _rest, acc), do: acc

  # Empty line (can appear inside a block due to splitting edge cases)
  defp parse_line("", acc), do: acc

  # Field line
  defp parse_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        apply_field(field, strip_leading_space(value), acc)

      # Line with no colon — ignore per spec
      [_] ->
        acc
    end
  end

  # Strip exactly one leading space from the value, per W3C SSE spec.
  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(value), do: value

  defp apply_field("event", value, acc), do: %{acc | event: value}
  defp apply_field("data", value, acc), do: %{acc | data: [value | acc.data]}
  defp apply_field("id", value, acc), do: %{acc | id: value}

  defp apply_field("retry", value, acc) do
    case Integer.parse(value) do
      {int, ""} -> %{acc | retry: int}
      _ -> acc
    end
  end

  # Unknown fields — ignored per spec
  defp apply_field(_field, _value, acc), do: acc
end
