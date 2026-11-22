defmodule Backplane.LLM.ResponsesWebSocket do
  @moduledoc """
  Native Responses WebSocket gateway with first-create model routing.

  `GET /v1/responses` selects an upstream from its first complete
  `response.create` message. Native Platform steering and Codex interrupts
  target responses observed on the pinned upstream. The transport does not
  reconnect, replay, or translate messages into REST lifecycle operations.
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
              remote_ip: conn.remote_ip,
              access: %{
                AccessEvent.start(conn, "responses.websocket.handshake", :openai_responses_ws)
                | stream?: true
              }}
           ) do
      upgrade(conn, session, limits)
    else
      {:error, :invalid_upgrade} -> error(conn, 400, "invalid_upgrade")
      _ -> error(conn, 503, "responses_websocket_unavailable")
    end
  rescue
    _ -> error(conn, 503, "responses_websocket_unavailable")
  end

  @doc false
  def route(conn, access, bytes, codec_options) do
    case route_with_params(conn, access, bytes, codec_options) do
      {:ok, opts, _params} -> {:ok, opts}
      {:error, _} = error -> error
    end
  end

  @doc false
  def route_with_params(conn, access, bytes, codec_options) do
    {result, _context} = route_submission(conn, access, bytes, codec_options)
    result
  end

  @doc false
  def route_submission(conn, access, bytes, codec_options) do
    {create, context} = Policy.decode_create_submission(bytes, codec_options)
    {route_create(conn, access, create), context}
  rescue
    _ -> {{:error, {503, "responses_websocket_unavailable"}}, nil}
  end

  defp route_create(conn, access, create) do
    with {:ok, params, model} <- create,
         :ok <- Policy.authorize_request(conn),
         {:ok, route} <- Policy.resolve(model),
         :ok <- Policy.validate_create_params(params, route),
         {:ok, headers, credential} <- Headers.build(conn, route),
         {:ok, policy} <- Policy.pin(route, conn, credential),
         {:ok, url} <- upstream_url(route) do
      access =
        if access do
          access
          |> AccessEvent.put_requested_model(route.requested)
          |> AccessEvent.put_resolution(route.provider, route.raw, route.api)
          |> AccessEvent.mark_upstream_start()
        end

      {:ok,
       [remote_ip: conn.remote_ip, url: url, headers: headers, policy: policy, access: access],
       params}
    else
      {:error, :disabled} ->
        {:error, {501, "responses_websocket_disabled"}}

      {:error, :model_unavailable} ->
        {:error, {404, "model_unavailable"}}

      {:error, :principal_changed} ->
        {:error, {403, "principal_changed"}}

      {:error, :message_too_big} ->
        {:error, {413, "message_too_big"}}

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

  defp upgrade(conn, session, limits) do
    Adapter.upgrade(conn, Socket, %{session: session, limits: limits},
      compress: false,
      timeout: limits.downstream_read_timeout_ms,
      max_frame_size: limits.max_message_bytes,
      max_message_size: limits.max_message_bytes,
      callback_timeout: limits.callback_timeout_ms,
      close_timeout: limits.close_timeout_ms,
      max_mailbox: 64,
      max_fragments: 1024,
      max_push_frames: 2,
      max_lifetime: limits.max_lifetime_ms
    )
  rescue
    _ ->
      Session.close(session, %{initiator: :gateway, cause: "invalid_upgrade", status: 400})
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
