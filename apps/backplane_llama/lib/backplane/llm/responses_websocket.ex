defmodule Backplane.LLM.ResponsesWebSocket do
  @moduledoc """
  Native Responses WebSocket gateway with first-create model routing.

  `GET /v1/responses` selects an upstream from its first complete
  `response.create` message. No reconnect, replay, REST lifecycle,
  interrupt or steering semantics are inferred from this transport.
  """
  import Plug.Conn
  alias Backplane.LLM.AccessEvent
  alias Backplane.LLM.ResponsesWebSocket.{Headers, Limits, Policy, Session, Socket}
  alias Relayixir.Proxy.WebSocket.Adapter

  def call(conn) do
    limits = Limits.current()

    with :ok <- upgrade_request(conn),
         {:ok, session} <-
           DynamicSupervisor.start_child(
             __MODULE__.Supervisor,
             {Session,
              owner: self(),
              limits: limits,
              request: routing_context(conn),
              access: %{
                AccessEvent.start(conn, "responses.websocket.handshake", :openai_responses_ws)
                | stream?: true
              }}
           ) do
      upgrade(conn, session, limits.max_message_bytes)
    else
      {:error, :invalid_upgrade} -> error(conn, 400, "invalid_upgrade")
      _ -> error(conn, 503, "responses_websocket_unavailable")
    end
  rescue
    _ -> error(conn, 503, "responses_websocket_unavailable")
  end

  @doc false
  def route(conn, access, bytes, codec_options) do
    with {:ok, model} <- Policy.request_model(bytes, codec_options),
         :ok <- Policy.authorize_request(conn),
         {:ok, route} <- Policy.resolve(model),
         {:ok, headers, credential} <- Headers.build(conn, route),
         {:ok, policy} <- Policy.pin(route, conn, credential),
         {:ok, url} <- upstream_url(route) do
      access =
        access
        |> AccessEvent.put_requested_model(route.requested)
        |> AccessEvent.put_resolution(route.provider, route.raw, route.api)
        |> AccessEvent.mark_upstream_start()

      {:ok,
       [remote_ip: conn.remote_ip, url: url, headers: headers, policy: policy, access: access]}
    else
      {:error, :disabled} ->
        {:error, {501, "responses_websocket_disabled"}}

      {:error, :model_unavailable} ->
        {:error, {404, "model_unavailable"}}

      {:error, :principal_changed} ->
        {:error, {403, "principal_changed"}}

      {:error, reason} when reason in [:invalid_model, :invalid_request] ->
        {:error, {400, Atom.to_string(reason)}}

      _ ->
        {:error, {503, "responses_websocket_unavailable"}}
    end
  rescue
    _ -> {:error, {503, "responses_websocket_unavailable"}}
  end

  @doc false
  def upstream_error(%{status: status}) when status in 400..599,
    do: {status, "upstream_websocket_rejected"}

  def upstream_error(_), do: {502, "upstream_websocket_unavailable"}

  defp routing_context(conn) do
    %Plug.Conn{
      req_headers: conn.req_headers,
      assigns: Map.take(conn.assigns, [:resource_auth]),
      remote_ip: conn.remote_ip
    }
  end

  defp upgrade(conn, session, max_message_bytes) do
    Adapter.upgrade(conn, Socket, session,
      compress: false,
      timeout: 60_000,
      max_frame_size: max_message_bytes,
      max_message_size: max_message_bytes,
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

  defp error(conn, status, code) do
    conn
    |> put_resp_header("x-should-retry", "false")
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Formata.JSON.encode!(%{error: %{type: "responses_websocket_error", code: code}})
    )
  end
end
