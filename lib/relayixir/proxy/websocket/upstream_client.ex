defmodule Relayixir.Proxy.WebSocket.UpstreamClient do
  @moduledoc """
  Establishes and manages upstream WebSocket connections via Mint + Mint.WebSocket.
  """

  require Logger

  alias Relayixir.Proxy.WebSocket.Frame

  @doc """
  Connects to upstream WebSocket. Returns `{:ok, conn, ref, websocket}` or `{:error, reason}`.
  """
  @spec connect(Relayixir.Proxy.Upstream.t(), [{String.t(), String.t()}]) ::
          {:ok, Mint.HTTP.t(), Mint.Types.request_ref(), Mint.WebSocket.t()} | {:error, term()}
  def connect(upstream, headers \\ []) do
    scheme = upstream.scheme || :http
    ws_scheme = if scheme == :https, do: :wss, else: :ws
    connect_timeout = Map.get(upstream, :connect_timeout, 5_000)

    case Mint.HTTP.connect(scheme, upstream.host, upstream.port,
           transport_opts: [timeout: connect_timeout]
         ) do
      {:ok, conn} ->
        path = build_path(upstream)
        ws_headers = prepare_ws_headers(headers, upstream)
        do_upgrade(conn, ws_scheme, path, ws_headers)

      {:error, reason} ->
        Logger.error("WebSocket upstream connect failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_upgrade(conn, ws_scheme, path, ws_headers) do
    case Mint.WebSocket.upgrade(ws_scheme, conn, path, ws_headers) do
      {:ok, conn, ref} ->
        case await_upgrade_response(conn, ref) do
          {:ok, conn, websocket} ->
            {:ok, conn, ref, websocket}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            Logger.error("WebSocket upstream connect failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        Logger.error("WebSocket upstream upgrade failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sends a frame to the upstream WebSocket.
  """
  @spec send_frame(Mint.HTTP.t(), Mint.WebSocket.t(), Mint.Types.request_ref(), Frame.t()) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.t(), term()}
  def send_frame(conn, websocket, ref, %Frame{} = frame) do
    mint_frame = Frame.to_mint(frame)

    case Mint.WebSocket.encode(websocket, mint_frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} -> {:ok, conn, websocket}
          {:error, conn, reason} -> {:error, conn, websocket, reason}
        end

      {:error, websocket, reason} ->
        {:error, conn, websocket, reason}
    end
  end

  @doc """
  Decodes incoming data from the upstream WebSocket connection.
  Returns `{:ok, conn, websocket, frames}` or `{:error, reason}`.
  """
  @spec decode_message(Mint.HTTP.t(), Mint.WebSocket.t(), term()) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t(), [Frame.t()]}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.t(), term()}
  def decode_message(conn, websocket, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, [{:data, _ref, data}]} ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            normalized = Enum.map(frames, &Frame.from_mint/1)
            {:ok, conn, websocket, normalized}

          {:error, websocket, reason} ->
            {:error, conn, websocket, reason}
        end

      {:ok, conn, _other} ->
        {:ok, conn, websocket, []}

      {:error, conn, reason, _responses} ->
        {:error, conn, websocket, reason}

      :unknown ->
        {:ok, conn, websocket, []}
    end
  end

  @doc """
  Closes the upstream connection.
  """
  @spec close(Mint.HTTP.t()) :: {:ok, Mint.HTTP.t()}
  def close(conn) do
    Mint.HTTP.close(conn)
  end

  defp build_path(upstream) do
    case upstream.path_prefix_rewrite do
      nil -> "/"
      path -> path
    end
  end

  defp prepare_ws_headers(headers, upstream) do
    headers
    |> Enum.reject(fn {name, _} ->
      downcased = String.downcase(name)
      downcased in ["host", "upgrade", "connection", "sec-websocket-version", "sec-websocket-key"]
    end)
    |> filter_extensions()
    |> maybe_add_host(upstream)
  end

  defp filter_extensions(headers) do
    Enum.reject(headers, fn {name, value} ->
      String.downcase(name) == "sec-websocket-extensions" &&
        String.contains?(String.downcase(value), "permessage-deflate")
    end)
  end

  defp maybe_add_host(headers, upstream) do
    host =
      case upstream.port do
        80 -> upstream.host
        443 -> upstream.host
        port -> "#{upstream.host}:#{port}"
      end

    [{"host", host} | headers]
  end

  defp await_upgrade_response(conn, ref) do
    receive do
      {:tcp, _, _} = message -> process_upgrade_message(conn, ref, message)
      {:tcp_closed, _} = message -> process_upgrade_message(conn, ref, message)
      {:tcp_error, _, _} = message -> process_upgrade_message(conn, ref, message)
      {:ssl, _, _} = message -> process_upgrade_message(conn, ref, message)
      {:ssl_closed, _} = message -> process_upgrade_message(conn, ref, message)
      {:ssl_error, _, _} = message -> process_upgrade_message(conn, ref, message)
    after
      10_000 ->
        {:error, conn, :handshake_timeout}
    end
  end

  defp process_upgrade_message(conn, ref, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        case extract_upgrade_info(responses) do
          {:ok, 101, resp_headers} ->
            case Mint.WebSocket.new(conn, ref, 101, resp_headers) do
              {:ok, conn, websocket} -> {:ok, conn, websocket}
              {:error, conn, reason} -> {:error, conn, reason}
            end

          {:ok, status, _headers} ->
            {:error, conn, {:unexpected_status, status}}

          :no_status ->
            {:error, conn, :no_upgrade_response}
        end

      {:error, conn, reason, _} ->
        {:error, conn, reason}

      :unknown ->
        await_upgrade_response(conn, ref)
    end
  end

  defp extract_upgrade_info(responses) do
    Enum.reduce(responses, {nil, []}, fn
      {:status, _ref, status}, {_s, h} -> {status, h}
      {:headers, _ref, headers}, {s, _h} -> {s, headers}
      _, acc -> acc
    end)
    |> case do
      {nil, _} -> :no_status
      {status, headers} -> {:ok, status, headers}
    end
  end
end
