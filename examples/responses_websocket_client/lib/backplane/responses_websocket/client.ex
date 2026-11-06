defmodule Backplane.ResponsesWebSocket.Client do
  @moduledoc """
  Standalone, caller-owned native Responses WebSocket reference client.

  Requires the published HTTP 1.0.0-rc.3 family in the consumer's dependency
  graph. It is not loaded by the Backplane umbrella. The creating process must
  perform all operations; its death tears down the upstream via HTTP.WebSocket.
  No operation reconnects, retries, steers, or cancels a provider response.

  Only the dependency's two selected handshake headers are available. The host
  owns credentials, endpoint/model selection, response correlation and policy.
  `:submission_unknown` must not trigger automatic replay. A receive timeout
  leaves the session open; callers must close it explicitly when abandoning it.
  `close/1` confirms local resource cleanup, not provider cancellation.
  """

  alias Backplane.AiProtocol.OpenAIResponsesWebSocket, as: Protocol
  alias HTTP.{ClientCompletion, WebSocket}
  alias HTTP.WebSocket.Event

  @derive {Inspect, only: [:owner]}
  @enforce_keys [:socket, :owner, :codec_opts]
  defstruct [:socket, :owner, :codec_opts, :max_outbound_bytes]

  @timeout 5_000

  @doc "Opens a caller-owned connection using explicit host-provided headers."
  def open(url, headers \\ [], opts \\ []) do
    if valid_url?(url) do
      options =
        opts
        |> Keyword.take([
          :connect_address,
          :ssl,
          :max_message_size,
          :max_frame_bytes,
          :max_read_bytes,
          :max_queue_bytes,
          :max_queue_events
        ])
        |> Keyword.put_new(:max_message_size, Keyword.get(opts, :max_encoded_bytes, 2_097_152))
        |> Keyword.merge(
          headers: headers,
          mode: :browser,
          delivery: :ack,
          http_version: :http1,
          connect_timeout: @timeout,
          opening_timeout: @timeout,
          write_timeout: @timeout,
          close_timeout: 1_000,
          telemetry_url: nil
        )

      case WebSocket.new(url, [], options) do
        %WebSocket{} = socket ->
          client = %__MODULE__{
            socket: socket,
            owner: self(),
            codec_opts: Keyword.take(opts, [:limits, :max_encoded_bytes])
          }

          await_open(client)

        {:error, _reason} ->
          {:error, :invalid_transport_options}
      end
    else
      {:error, :invalid_endpoint}
    end
  end

  @doc "Sends one native creation message; success confirms local write only."
  def create(%__MODULE__{owner: owner} = client, params) when owner == self() do
    with {:ok, bytes} <- Protocol.encode_create(params, client.codec_opts),
         :ok <- within_peer_limit(client, bytes) do
      case WebSocket.send_ack(client.socket, bytes) do
        {:ok, ref} -> await_send(client, ref)
        {:error, _reason} -> uncertain(client)
      end
    end
  end

  def create(%__MODULE__{}, _params), do: {:error, :wrong_owner}

  @doc "Reads one native event. Provider error events are data, not automatic retry instructions."
  def next_event(client, timeout \\ @timeout)

  def next_event(%__MODULE__{owner: owner, socket: socket} = client, timeout)
      when owner == self() and is_integer(timeout) and timeout >= 0 do
    receive do
      {WebSocket, ^socket, %Event.Message{data: bytes}, ref} ->
        result = Protocol.decode_event(bytes, client.codec_opts)
        WebSocket.acknowledge(socket, ref)

        case result do
          {:ok, event} -> {:ok, event}
          {:error, _} -> {:error, :invalid_event, close(client)}
        end

      {WebSocket, ^socket, %Event.Error{}} ->
        {:error, :transport_failed, close(client)}

      {WebSocket, ^socket, %Event.Close{code: 1006}} ->
        {:error, :transport_failed, close(client)}

      {WebSocket, ^socket, %Event.Close{code: code}} ->
        {:closed, code, close(client)}
    after
      timeout -> {:error, :receive_timeout}
    end
  end

  def next_event(%__MODULE__{owner: owner}, _timeout) when owner != self(),
    do: {:error, :wrong_owner}

  def next_event(%__MODULE__{}, _timeout), do: {:error, :invalid_timeout}

  @doc "Returns the public cleanup receipt; safe to retain outside the socket owner."
  def completion(%__MODULE__{socket: socket}), do: WebSocket.completion(socket)

  @doc "Closes the connection and waits for the dependency's local cleanup barrier."
  def close(%__MODULE__{owner: owner, socket: socket}) when owner == self() do
    WebSocket.close(socket)
    ClientCompletion.await(WebSocket.completion(socket), @timeout)
  end

  def close(%__MODULE__{}), do: {:error, :wrong_owner}

  defp await_open(%{socket: socket} = client) do
    monitor = Process.monitor(socket.pid)

    result =
      receive do
        {WebSocket, ^socket, %Event.Open{handshake: handshake}} ->
          admit_handshake(client, handshake)

        {WebSocket, ^socket, %Event.Error{handshake: handshake}} ->
          {:error, :handshake_failed, handshake, close(client)}

        {WebSocket, ^socket, %Event.Close{}} ->
          {:error, :handshake_closed, close(client)}

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          {:error, :handshake_closed, close(client)}
      after
        @timeout + 100 -> {:error, :handshake_timeout, close(client)}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp admit_handshake(client, %{truncated?: true} = handshake),
    do: {:error, :handshake_metadata_truncated, handshake, close(client)}

  defp admit_handshake(client, %{headers: headers} = handshake) do
    configured = Keyword.get(client.codec_opts, :max_encoded_bytes, 2_097_152)

    case HTTP.Headers.get(headers, "x-codex-websocket-max-unfragmented-message-bytes") do
      nil ->
        {:ok, %{client | max_outbound_bytes: configured}, handshake}

      value ->
        case Integer.parse(value) do
          {limit, ""} when limit > 0 ->
            {:ok, %{client | max_outbound_bytes: min(configured, limit)}, handshake}

          _ ->
            {:error, :invalid_peer_message_limit, handshake, close(client)}
        end
    end
  end

  defp within_peer_limit(client, bytes) do
    if byte_size(bytes) <= client.max_outbound_bytes,
      do: :ok,
      else: {:error, :message_exceeds_peer_limit}
  end

  defp await_send(%{socket: socket} = client, ref) do
    receive do
      {WebSocket, ^socket, {:send_result, ^ref, :ok}} -> :ok
      {WebSocket, ^socket, {:send_result, ^ref, {:error, _reason}}} -> uncertain(client)
    after
      @timeout + 100 -> uncertain(client)
    end
  end

  defp uncertain(client), do: {:error, :submission_unknown, close(client)}

  defp valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %{scheme: scheme, host: host, userinfo: nil, fragment: nil}}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_url?(_url), do: false
end
