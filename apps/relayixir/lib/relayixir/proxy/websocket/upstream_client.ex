defmodule Relayixir.Proxy.WebSocket.UpstreamClient do
  @moduledoc """
  Establishes and manages upstream connections through HTTP.WebSocket's proxy API.
  """

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event
  alias Relayixir.Proxy.WebSocket.{Close, Frame}

  @handshake_timeout 10_000
  @write_timeout 5_000

  @doc """
  Connects to the upstream WebSocket and waits for its validated handshake.
  """
  @spec connect(Relayixir.Proxy.Upstream.t(), [{String.t(), String.t()}]) ::
          {:ok, WebSocket.t()} | {:error, term()}
  def connect(upstream, headers \\ []) do
    {protocols, headers} = prepare_ws_headers(headers)
    opening_timeout = upstream.connect_timeout + @handshake_timeout

    case WebSocket.new(build_url(upstream), protocols,
           headers: headers,
           mode: :proxy,
           automatic_pong: false,
           delivery: :ack,
           http_version: :http1,
           tls_backend: :ssl,
           connect_timeout: upstream.connect_timeout,
           opening_timeout: opening_timeout,
           write_timeout: @write_timeout,
           close_timeout: Close.close_timeout()
         ) do
      %WebSocket{} = socket -> await_open(socket, opening_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a frame and waits for local transport completion before admitting the next one.
  In particular, Close must follow successful completion of all preceding writes.
  """
  @spec send_frame(WebSocket.t(), Frame.t()) :: :ok | {:error, term()}
  def send_frame(socket, %Frame{type: :close, close_code: code, close_reason: reason}) do
    WebSocket.close(socket, code, reason)
  end

  def send_frame(socket, %Frame{type: opcode, payload: payload}) do
    with {:ok, ref} <- WebSocket.send_frame_ack(socket, {opcode, payload}) do
      receive do
        {WebSocket, ^socket, {:send_result, ^ref, result}} -> result
      after
        @write_timeout + 100 -> {:error, :send_timeout}
      end
    end
  end

  @doc """
  Normalizes public proxy events, retaining the delivery reference for acknowledgement
  after the bridge forwards the frame to downstream.
  """
  @spec decode_message(WebSocket.t(), term()) ::
          {:ok, [Frame.t()], reference() | nil} | {:error, term()}
  def decode_message(socket, {WebSocket, socket, %Event.Frame{opcode: opcode, data: data}, ref}) do
    {:ok, [%Frame{type: opcode, payload: data}], ref}
  end

  def decode_message(socket, {WebSocket, socket, %Event.Close{code: 1006}}) do
    {:error, :closed}
  end

  def decode_message(socket, {WebSocket, socket, %Event.Close{code: code, reason: reason}}) do
    {:ok, [Frame.close(code || 1000, reason)], nil}
  end

  def decode_message(socket, {WebSocket, socket, %Event.Error{reason: reason}}) do
    {:error, reason}
  end

  def decode_message(_socket, _message), do: {:ok, [], nil}

  @doc """
  Initiates cancellation. Owner death also tears down the connection and pending IO.
  """
  @spec close(WebSocket.t()) :: :ok | {:error, term()}
  def close(socket), do: WebSocket.close(socket)

  defp await_open(socket, opening_timeout) do
    monitor = Process.monitor(socket.pid)

    result =
      receive do
        {WebSocket, ^socket, %Event.Open{}} -> {:ok, socket}
        {WebSocket, ^socket, %Event.Error{reason: reason}} -> {:error, reason}
        {WebSocket, ^socket, %Event.Close{}} -> {:error, :closed}
        {:DOWN, ^monitor, :process, _pid, reason} -> {:error, reason}
      after
        opening_timeout + 100 -> {:error, :handshake_timeout}
      end

    Process.demonitor(monitor, [:flush])
    if match?({:error, _}, result), do: close(socket)
    result
  end

  defp build_url(upstream) do
    [path | query] = String.split(upstream.path_prefix_rewrite || "/", "?", parts: 2)
    scheme = if(upstream.scheme == :https, do: "wss", else: "ws")
    uri = URI.parse("#{scheme}:")

    URI.to_string(%{
      uri
      | host: upstream.host,
        port: upstream.port,
        path: path,
        query: List.first(query)
    })
  end

  defp prepare_ws_headers(headers) do
    protocols =
      headers
      |> Enum.filter(fn {name, _} -> String.downcase(name) == "sec-websocket-protocol" end)
      |> Enum.flat_map(fn {_, value} -> String.split(value, ",", trim: true) end)
      |> Enum.map(&String.trim/1)

    headers =
      Enum.reject(headers, fn {name, value} ->
        name = String.downcase(name)

        name in [
          "host",
          "upgrade",
          "connection",
          "sec-websocket-version",
          "sec-websocket-key",
          "sec-websocket-protocol"
        ] or
          (name == "sec-websocket-extensions" and
             String.contains?(String.downcase(value), "permessage-deflate"))
      end)

    {protocols, headers}
  end
end
