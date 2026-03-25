defmodule Backplane.Transport.SSE do
  @moduledoc """
  SSE (Server-Sent Events) streaming support for MCP Streamable HTTP transport.

  When a client sends `Accept: text/event-stream`, tool call responses are
  streamed as SSE events instead of returned as a single JSON response.

  Event format follows the MCP Streamable HTTP spec:
  - Each event has `event: message` and `data: <JSON-RPC response>`
  - The stream is terminated after the final result event
  """

  import Plug.Conn

  @doc """
  Returns true if the client requested SSE streaming via Accept header.
  """
  def streaming_requested?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  @doc """
  Initiates an SSE stream on the connection.

  Sets appropriate headers and sends the initial response to begin chunked transfer.
  Returns the updated conn for subsequent `send_event/3` calls.
  """
  def start_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  @doc """
  Sends a single SSE event with a JSON-RPC message.

  The event type is always "message" per the MCP spec.
  """
  def send_event(conn, id, result) do
    message =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        result: result
      })

    chunk_data = "event: message\ndata: #{message}\n\n"
    {:ok, conn} = chunk(conn, chunk_data)
    conn
  end

  @doc """
  Sends a JSON-RPC error as an SSE event.
  """
  def send_error_event(conn, id, code, message) do
    error_message =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        error: %{code: code, message: message}
      })

    chunk_data = "event: message\ndata: #{error_message}\n\n"
    {:ok, conn} = chunk(conn, chunk_data)
    conn
  end
end
