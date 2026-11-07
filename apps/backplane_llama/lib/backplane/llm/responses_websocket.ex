defmodule Backplane.LLM.ResponsesWebSocket do
  @moduledoc """
  Native Responses WebSocket gateway with explicit handshake-time model routing.

  `GET /v1/responses?model=provider/model` pins a single upstream. Only complete
  JSON creation messages are admitted. No reconnect, replay, REST lifecycle,
  interrupt or steering semantics are inferred from this transport.
  """
  import Plug.Conn
  alias Backplane.LLM.ResponsesWebSocket.{Headers, Policy, Session, Socket}
  alias Relayixir.Proxy.WebSocket.Adapter

  def call(conn) do
    conn = fetch_query_params(conn)

    with {:ok, model} <- query_model(conn),
         {:ok, route} <- Policy.resolve(model),
         :ok <- upgrade_request(conn),
         {:ok, headers, credential} <- Headers.build(conn, route),
         {:ok, policy} <- Policy.pin(route, conn, credential),
         {:ok, url} <- upstream_url(route),
         {:ok, session} <-
           DynamicSupervisor.start_child(
             __MODULE__.Supervisor,
             {Session, owner: self(), url: url, headers: headers, policy: policy}
           ) do
      upgrade(conn, session)
    else
      {:error, :disabled} ->
        error(conn, 501, "responses_websocket_disabled")

      {:error, :model_unavailable} ->
        error(conn, 404, "model_unavailable")

      {:error, reason}
      when reason in [
             :invalid_model,
             :invalid_upgrade,
             :unsupported_query,
             :unsupported_subprotocol
           ] ->
        error(conn, 400, Atom.to_string(reason))

      _ ->
        error(conn, 503, "responses_websocket_unavailable")
    end
  rescue
    _ -> error(conn, 503, "responses_websocket_unavailable")
  end

  defp upgrade(conn, session) do
    case Session.open(session) do
      {:ok, metadata} ->
        try do
          conn
          |> handshake_headers(metadata)
          |> Adapter.upgrade(Socket, %{session: session},
            compress: false,
            timeout: 60_000,
            max_frame_size: Policy.max_bytes(),
            max_message_size: Policy.max_bytes(),
            callback_timeout: 15_000,
            close_timeout: 1_000,
            max_mailbox: 64,
            max_fragments: 1024,
            max_push_frames: 1,
            max_lifetime: 300_000
          )
        rescue
          _ ->
            Session.close(session)
            error(conn, 400, "invalid_upgrade")
        end

      {:error, :session_unavailable} ->
        Session.close(session)
        error(conn, 502, "upstream_websocket_unavailable")

      {:error, _reason, metadata} ->
        status =
          if is_map(metadata) and metadata.status in 400..599, do: metadata.status, else: 502

        conn |> handshake_headers(metadata) |> error(status, "upstream_websocket_rejected")
    end
  end

  defp query_model(conn) do
    pairs = URI.query_decoder(conn.query_string) |> Enum.to_list()

    case pairs do
      [{"model", model}] when byte_size(model) in 1..1024 -> {:ok, model}
      [] -> {:error, :invalid_model}
      _ -> {:error, :unsupported_query}
    end
  rescue
    _ -> {:error, :unsupported_query}
  end

  defp upgrade_request(conn) do
    with :ok <- Adapter.validate_upgrade(conn),
         [key] <- get_req_header(conn, "sec-websocket-key"),
         {:ok, decoded} <- Base.decode64(key),
         true <- byte_size(decoded) == 16,
         [] <- get_req_header(conn, "sec-websocket-protocol") do
      :ok
    else
      _ -> {:error, :invalid_upgrade}
    end
  end

  defp upstream_url(route) do
    uri = URI.parse(route.api.base_url)

    path =
      case uri.path do
        value when value in [nil, "", "/"] -> "/v1/responses"
        value -> String.trim_trailing(value, "/") <> "/responses"
      end

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok,
       URI.to_string(%{
         uri
         | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
           path: path,
           query: nil
       })}
    else
      {:error, :invalid_upstream_endpoint}
    end
  end

  defp handshake_headers(conn, %{headers: headers}) do
    Enum.reduce(~w(retry-after x-codex-websocket-max-unfragmented-message-bytes), conn, fn name,
                                                                                           acc ->
      case HTTP.Headers.get(headers, name) do
        nil -> acc
        value -> put_resp_header(acc, name, value)
      end
    end)
  end

  defp handshake_headers(conn, _), do: conn

  defp error(conn, status, code) do
    conn
    |> put_resp_header("x-should-retry", "false")
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{error: %{type: "responses_websocket_error", code: code}})
    )
  end
end
