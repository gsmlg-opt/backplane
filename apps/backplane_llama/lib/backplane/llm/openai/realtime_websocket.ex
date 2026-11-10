defmodule Backplane.LLM.OpenAI.RealtimeWebSocket do
  @moduledoc """
  Native Realtime WebSocket proxy with one model and provider per connection.

  Query model selection uses the independently configured Realtime service.
  Native audio, session, cancellation, and future JSON events remain upstream
  protocols; this gateway does not reconnect or replay events.
  """

  import Plug.Conn

  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.AccessEvent
  alias Backplane.LLM.OpenAI.RealtimeWebSocket.{Policy, Session, Socket}
  alias Relayixir.Proxy.WebSocket.Adapter

  @client_headers ~w(openai-safety-identifier x-client-request-id)

  def call(conn) do
    with {:ok, model} <- query_model(conn),
         :ok <- upgrade_request(conn),
         {:ok, route} <- Service.resolve(:realtime, model),
         {:ok, policy, headers} <- Policy.pin(route, conn),
         {:ok, url} <- upstream_url(route),
         {:ok, session} <-
           DynamicSupervisor.start_child(
             __MODULE__.Supervisor,
             {Session,
              owner: self(),
              remote_ip: conn.remote_ip,
              url: url,
              headers: headers(conn, headers),
              policy: policy,
              access: access(conn, route)}
           ) do
      upgrade(conn, session, policy)
    else
      {:error, reason} when reason in [:invalid_model, :invalid_upgrade, :unsupported_query] ->
        error(conn, 400, Atom.to_string(reason))

      {:error, :rate_limited} ->
        error(conn, 429, "rate_limited")

      {:error, reason} when reason in [:no_provider, :model_unavailable, :ambiguous_model] ->
        error(conn, 404, Atom.to_string(reason))

      _ ->
        error(conn, 503, "realtime_unavailable")
    end
  rescue
    _ -> error(conn, 503, "realtime_unavailable")
  end

  defp access(conn, route) do
    access =
      conn
      |> AccessEvent.start("realtime.connection", :openai_realtime)
      |> AccessEvent.put_requested_model(route.requested_model)
      |> AccessEvent.put_resolution(route.provider, route.raw_model, route.api)
      |> AccessEvent.mark_upstream_start()

    %{access | stream?: true}
  end

  defp upgrade(conn, session, policy) do
    case Session.open(session) do
      {:ok, metadata} ->
        try do
          conn
          |> handshake_headers(metadata)
          |> Adapter.upgrade(Socket, %{session: session},
            compress: false,
            timeout: min(policy.service.max_session_ms, 300_000),
            max_frame_size: Policy.max_bytes(policy),
            max_message_size: Policy.max_bytes(policy),
            callback_timeout: 15_000,
            close_timeout: 1_000,
            max_mailbox: 64,
            max_fragments: 1024,
            max_push_frames: 1,
            max_lifetime: policy.service.max_session_ms
          )
        rescue
          _ ->
            Session.close(session)
            error(conn, 400, "invalid_upgrade")
        end

      {:error, _reason, metadata} ->
        status =
          if is_map(metadata) and metadata.status in 400..599, do: metadata.status, else: 502

        conn |> handshake_headers(metadata) |> error(status, "upstream_websocket_rejected")

      _ ->
        Session.close(session)
        error(conn, 502, "upstream_websocket_unavailable")
    end
  end

  defp query_model(conn) do
    case URI.query_decoder(conn.query_string) |> Enum.to_list() do
      [{"model", model}] when byte_size(model) in 1..1024 -> {:ok, model}
      [] -> {:ok, nil}
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
    uri = URI.parse(Service.url(route, "realtime"))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok,
       URI.to_string(%{
         uri
         | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
           query: URI.encode_query(%{"model" => route.raw_model})
       })}
    else
      {:error, :invalid_upstream_endpoint}
    end
  end

  defp headers(conn, configured) do
    nominated =
      conn
      |> get_req_header("connection")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.downcase(String.trim(&1)))

    client =
      Enum.filter(conn.req_headers, fn {name, _} ->
        name in @client_headers and name not in nominated
      end)

    Map.new(client ++ configured) |> Enum.to_list()
  end

  defp handshake_headers(conn, %{headers: headers}) do
    case HTTP.Headers.get(headers, "retry-after") do
      nil -> conn
      value -> put_resp_header(conn, "retry-after", value)
    end
  end

  defp handshake_headers(conn, _), do: conn

  defp error(conn, status, code) do
    conn
    |> put_resp_header("x-should-retry", "false")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{type: "realtime_proxy_error", code: code}}))
  end
end
