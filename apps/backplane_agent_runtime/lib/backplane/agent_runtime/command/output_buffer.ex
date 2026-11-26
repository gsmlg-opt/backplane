defmodule Backplane.AgentRuntime.Command.OutputBuffer do
  @moduledoc "Bounded command output retaining a stable head and recent tail with byte cursors."

  def new(limit) when is_integer(limit) and limit >= 0,
    do: %{limit: limit, head: "", tail: "", total: 0}

  def append(buffer, bytes) when is_binary(bytes) do
    head_limit = div(buffer.limit, 2)
    taken = min(max(head_limit - byte_size(buffer.head), 0), byte_size(bytes))
    <<head::binary-size(^taken), rest::binary>> = bytes
    tail = buffer.tail <> rest
    tail_limit = buffer.limit - head_limit

    tail =
      binary_part(tail, max(byte_size(tail) - tail_limit, 0), min(byte_size(tail), tail_limit))

    %{buffer | head: buffer.head <> head, tail: tail, total: buffer.total + byte_size(bytes)}
  end

  def read(buffer, cursor) do
    head = after_cursor(buffer.head, 0, cursor)
    tail = after_cursor(buffer.tail, buffer.total - byte_size(buffer.tail), cursor)

    {output, pending} =
      if buffer.total <= buffer.limit do
        utf8(head <> tail)
      else
        {head, _omitted} = utf8(head)
        {tail, pending} = utf8(tail)
        {head <> tail, pending}
      end

    # A later frame can complete this suffix; do not consume it on this poll.
    {output, buffer.total - pending}
  end

  defp utf8(bytes) do
    case :unicode.characters_to_binary(bytes) do
      valid when is_binary(valid) ->
        {valid, 0}

      {:incomplete, valid, pending} ->
        {valid, byte_size(pending)}

      {:error, valid, <<_, rest::binary>>} ->
        {suffix, pending} = utf8(rest)
        {valid <> suffix, pending}
    end
  end

  defp after_cursor(bytes, offset, cursor) do
    skip = min(max(cursor - offset, 0), byte_size(bytes))
    binary_part(bytes, skip, byte_size(bytes) - skip)
  end
end
