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

  alias Backplane.McpProtocol.Sse

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
    {events, rest} = Sse.parse(chunk, buffer)

    {Enum.map(events, &to_proxy_event/1), rest}
  end

  defp to_proxy_event(event) do
    %__MODULE__{
      event: event.event,
      data: event.data,
      id: event.id,
      retry: event.retry
    }
  end
end
