defmodule Relayixir.Proxy.WebSocket.Adapter do
  @moduledoc """
  Relayixir-owned WebSock upgrade adapter for Bandit.

  This keeps Relayixir's WebSocket server handoff local instead of depending on
  a generic adapter package. Relayixir only supports Bandit as its inbound
  server, so the adapter intentionally covers the Bandit and Plug test adapter
  upgrade contracts.
  """

  defmodule UpgradeError do
    @moduledoc """
    Raised when a request cannot be upgraded to WebSocket.
    """

    defexception [:reason]

    @impl Exception
    def message(%__MODULE__{reason: reason}) do
      "invalid WebSocket upgrade: #{reason}"
    end
  end

  @type connection_opt ::
          {:compress, boolean()}
          | {:timeout, timeout()}
          | {:max_frame_size, non_neg_integer()}
          | {:max_fragmented_message_size, non_neg_integer()}
          | {:fullsweep_after, non_neg_integer()}
          | {:max_heap_size, :erlang.max_heap_size()}
          | {:validate_text_frames, boolean()}
          | {:deflate_options, keyword()}
          | {:early_validate_upgrade, boolean()}

  @bandit_adapters [Bandit.Adapter, Bandit.HTTP1.Adapter, Bandit.HTTP2.Adapter]

  @doc """
  Upgrades a `Plug.Conn` to a Bandit WebSock connection.

  The returned connection is marked `:upgraded`; Bandit performs the actual
  handshake after the Plug lifecycle returns. Set `:early_validate_upgrade` to
  `false` to skip Relayixir's preflight validation.
  """
  @spec upgrade(Plug.Conn.t(), WebSock.impl(), WebSock.state(), [connection_opt()]) ::
          Plug.Conn.t()
  def upgrade(conn, websock, state, opts \\ [])

  def upgrade(%Plug.Conn{adapter: {adapter, _}} = conn, websock, state, opts) do
    if Keyword.get(opts, :early_validate_upgrade, true) do
      validate_upgrade!(conn)
    end

    connection_opts = Keyword.delete(opts, :early_validate_upgrade)
    tuple = tuple_for(adapter, websock, state, connection_opts)

    Plug.Conn.upgrade_adapter(conn, :websocket, tuple)
  end

  @doc """
  Validates the request pieces required for an HTTP/1.1 WebSocket upgrade.
  """
  @spec validate_upgrade(Plug.Conn.t()) :: :ok | {:error, String.t()}
  def validate_upgrade(%Plug.Conn{} = conn) do
    case Plug.Conn.get_http_protocol(conn) do
      :"HTTP/1.1" -> validate_upgrade_http1(conn)
      other -> {:error, "HTTP version #{other} unsupported"}
    end
  end

  @doc """
  Like `validate_upgrade/1`, but raises `UpgradeError` on failure.
  """
  @spec validate_upgrade!(Plug.Conn.t()) :: :ok
  def validate_upgrade!(%Plug.Conn{} = conn) do
    case validate_upgrade(conn) do
      :ok -> :ok
      {:error, reason} -> raise UpgradeError, reason: reason
    end
  end

  defp tuple_for(adapter, websock, state, opts) when adapter in @bandit_adapters,
    do: {websock, state, opts}

  defp tuple_for(Plug.Adapters.Test.Conn, websock, state, opts), do: {websock, state, opts}

  defp tuple_for(adapter, _websock, _state, _opts),
    do: raise(ArgumentError, "unsupported WebSocket adapter #{inspect(adapter)}")

  defp validate_upgrade_http1(conn) do
    with :ok <- assert_method(conn, "GET"),
         :ok <- assert_host(conn),
         :ok <- assert_header_contains(conn, "connection", "upgrade"),
         :ok <- assert_header_contains(conn, "upgrade", "websocket"),
         :ok <- assert_header_nonempty(conn, "sec-websocket-key"),
         :ok <- assert_header_equals(conn, "sec-websocket-version", "13") do
      :ok
    end
  end

  defp assert_method(conn, verb) do
    case conn.method do
      ^verb -> :ok
      other -> {:error, "HTTP method #{other} unsupported"}
    end
  end

  defp assert_host(%Plug.Conn{host: host}) when is_binary(host) and host != "", do: :ok
  defp assert_host(_conn), do: {:error, "host is absent"}

  defp assert_header_nonempty(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] -> {:error, "'#{header}' header is absent"}
      _ -> :ok
    end
  end

  defp assert_header_equals(conn, header, expected) do
    case conn |> Plug.Conn.get_req_header(header) |> Enum.map(&String.downcase(&1, :ascii)) do
      [^expected] -> :ok
      value -> {:error, "'#{header}' header must equal '#{expected}', got #{inspect(value)}"}
    end
  end

  defp assert_header_contains(conn, header, expected) do
    values = Plug.Conn.get_req_header(conn, header)

    values
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.any?(&(String.downcase(&1, :ascii) == expected))
    |> case do
      true -> :ok
      false -> {:error, "'#{header}' header must contain '#{expected}', got #{inspect(values)}"}
    end
  end
end
