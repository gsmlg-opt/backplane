if Code.ensure_loaded?(Plug) do
  defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernRequest do
    @moduledoc """
    Dispatches one stateless modern MCP request over Streamable HTTP.

    The caller supplies request-local transport context and the runtime
    dependencies needed for callback isolation. No legacy session or server
    supervisor configuration is consulted.
    """

    use Backplane.McpProtocol.Logging

    import Plug.Conn

    alias Backplane.McpProtocol.MCP.Error
    alias Backplane.McpProtocol.Server.Modern.Executor
    alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernSubscription
    alias Backplane.McpProtocol.SSE.Event
    alias Backplane.McpProtocol.SSE.Streaming

    @default_timeout 30_000

    @doc "Dispatches and renders one decoded modern Streamable HTTP request."
    @spec call(Plug.Conn.t(), term(), map(), keyword()) :: Plug.Conn.t()
    def call(conn, message, transport_context, opts) when is_map(transport_context) and is_list(opts) do
      server = Keyword.fetch!(opts, :server)
      task_supervisor = Keyword.fetch!(opts, :task_supervisor)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      subscriptions = Keyword.get(opts, :subscriptions)

      runtime = %{
        server: server,
        task_supervisor: task_supervisor,
        timeout: timeout,
        subscriptions: subscriptions
      }

      transport_context =
        Map.merge(transport_context, %{
          task_supervisor: task_supervisor,
          request_timeout: timeout
        })

      dispatch(conn, message, transport_context, runtime)
    end

    @doc "Renders the modern JSON-RPC parse error used for malformed request bodies."
    @spec parse_error(Plug.Conn.t()) :: Plug.Conn.t()
    def parse_error(conn) do
      error = Error.protocol(:parse_error, %{message: "Invalid JSON"})
      send_response(conn, Error.build_json_rpc(error, nil))
    end

    defp dispatch(conn, message, transport_context, runtime) do
      case validate_request(message) do
        :ok -> dispatch_valid(conn, message, transport_context, runtime)
        {:error, %Error{} = error} -> send_response(conn, Error.build_json_rpc(error, nil))
      end
    end

    defp dispatch_valid(conn, %{"method" => "subscriptions/listen"} = message, _transport_context, %{subscriptions: nil}) do
      error = Error.protocol(:method_not_found)
      send_response(conn, Error.build_json_rpc(error, message["id"]))
    end

    defp dispatch_valid(conn, %{"method" => "subscriptions/listen"} = message, transport_context, runtime) do
      ModernSubscription.call(conn, message, transport_context, runtime)
    end

    defp dispatch_valid(conn, message, transport_context, runtime) do
      case Executor.execute(runtime.server, message, transport_context,
             task_supervisor: runtime.task_supervisor,
             timeout: runtime.timeout
           ) do
        {:response, response} ->
          send_response(conn, response)

        {:response, response, notifications} ->
          send_response(conn, response, notifications)
      end
    end

    defp validate_request(message) when is_map(message) do
      id = message["id"]

      if message["jsonrpc"] == "2.0" and
           is_binary(message["method"]) and
           (is_binary(id) or is_integer(id)) and
           is_map(message["params"]) and
           not Map.has_key?(message, "result") and
           not Map.has_key?(message, "error") do
        :ok
      else
        {:error, Error.protocol(:invalid_request)}
      end
    end

    defp validate_request(_message), do: {:error, Error.protocol(:invalid_request)}

    defp send_response(conn, response), do: send_response(conn, response, [])

    defp send_response(conn, response, notifications) do
      encoded = JSON.encode!(response)
      status = http_status(response)

      if status == 200 and (wants_sse?(conn) or (notifications != [] and accepts_sse?(conn))) do
        stream_response(conn, notifications ++ [response])
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, encoded)
      end
    end

    defp stream_response(conn, messages) do
      conn = Streaming.prepare_connection(conn)

      Enum.reduce_while(messages, conn, fn message, conn ->
        event = Event.encode(%Event{event: "message", data: JSON.encode!(message)})

        case Plug.Conn.chunk(conn, event) do
          {:ok, conn} ->
            {:cont, conn}

          {:error, reason} ->
            Logging.transport_event(
              "modern_sse_post_send_failed",
              %{reason: inspect(reason)},
              level: :warning
            )

            {:halt, conn}
        end
      end)
    end

    defp http_status(%{"error" => %{"code" => -32_601}}), do: 404

    defp http_status(%{"error" => %{"code" => code}}) when code in [-32_700, -32_600, -32_602, -32_020, -32_021, -32_022],
      do: 400

    defp http_status(_response), do: 200

    defp wants_sse?(conn) do
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> List.first("")
      |> String.starts_with?("text/event-stream")
    end

    defp accepts_sse?(conn) do
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.any?(fn media_range ->
        media_range
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("text/event-stream")
      end)
    end
  end
end
