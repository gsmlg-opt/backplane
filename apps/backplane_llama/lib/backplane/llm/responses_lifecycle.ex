defmodule Backplane.LLM.ResponsesLifecycle do
  @moduledoc """
  Opt-in native Responses lifecycle routing. The durable index is independent of
  usage logging; neither submission nor reconnection ever retries a generation.
  """

  import Plug.Conn

  alias Backplane.LLM.{AccessEvent, CredentialPlug, RateLimiter, ResponseRoute}
  alias Backplane.LLM.ResponsesLifecycleMapper, as: Mapper
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  def create(conn, upstream, _provider, %{responses_lifecycle: false}, opts),
    do: HttpPlug.call(conn, upstream, opts)

  def create(conn, upstream, provider, api, opts) do
    with :ok <- validate_request_context(conn),
         {:ok, route} <- ResponseRoute.admit(conn, provider, api) do
      conn = put_resp_header(conn, "x-backplane-response-attempt", route.id)
      opts = mapping_options(opts, route, :create, stream_body?(opts[:body]))

      result =
        with {:ok, credential} <- ResponseRoute.credential_snapshot(route),
             {:ok, headers} <- CredentialPlug.build_responses_auth_headers(provider, credential),
             :ok <- ResponseRoute.verify(route),
             :ok <- ResponseRoute.uncertain(route) do
          # Persist uncertainty before the send: caller/VM death can bypass every
          # finalizer after the provider has accepted the paid operation.
          upstream = %{upstream | inject_request_headers: headers}

          conn
          |> put_req_header("accept-encoding", "identity")
          |> HttpPlug.call(upstream, opts)
        else
          {:error, code} -> error(conn, code)
        end

      reconcile_attempt(route, result)
      result
    else
      {:error, code} -> error(conn, code)
    end
  end

  def call(conn, response_id, operation) do
    access = AccessEvent.start(conn, "responses.#{operation}", :openai_responses)

    {result, access} =
      case ResponseRoute.lookup(conn, response_id) do
        {:ok, route, provider, api} ->
          access = AccessEvent.put_resolution(access, provider, nil, api)
          dispatch(conn, route, provider, api, operation, access)

        {:error, code} ->
          {error(conn, code), access}
      end

    AccessEvent.finalize(access, result, outcome(result), status: result.status)
    result
  end

  defp dispatch(conn, route, provider, api, operation, access) do
    with :ok <- validate_request_context(conn),
         :ok <- RateLimiter.check(provider.id, provider.rpm_limit),
         {:ok, credential} <- ResponseRoute.credential_snapshot(route),
         {:ok, headers} <- CredentialPlug.build_responses_auth_headers(provider, credential),
         :ok <- ResponseRoute.verify(route) do
      proxy_lifecycle(conn, route, provider, api, headers, operation, access)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        {conn |> put_resp_header("retry-after", to_string(retry_after)) |> error(:rate_limited),
         access}

      {:error, code} ->
        {error(conn, code), access}
    end
  end

  defp proxy_lifecycle(conn, route, _provider, api, headers, operation, access) do
    uri = URI.parse(api.base_url)
    prefix = String.trim_trailing(uri.path || "", "/")
    suffix = if operation == :cancel, do: "/cancel", else: ""
    path = "/responses/" <> route.response_id <> suffix
    path = if prefix in ["", "/"], do: "/v1" <> path, else: path

    upstream = %Upstream{
      scheme: String.to_existing_atom(uri.scheme),
      host: uri.host,
      port: uri.port,
      path_prefix_rewrite: prefix,
      inject_request_headers: headers,
      host_forward_mode: :rewrite_to_upstream,
      proxy: :environment,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      max_response_body_size: 50_000_000,
      metadata: %{provider_api_id: api.id, api_surface: :openai}
    }

    stream? = stream_query?(conn.query_string)
    opts = mapping_options([body: conn.assigns[:raw_body] || ""], route, operation, stream?)
    # Replayed usage events must not be billed a second time by an accumulator.
    access = AccessEvent.mark_upstream_start(%{access | stream?: stream?})

    result =
      conn
      |> strip_authentication()
      |> put_req_header("accept-encoding", "identity")
      |> Map.put(:request_path, path)
      |> Map.put(:path_info, String.split(path, "/", trim: true))
      |> HttpPlug.call(upstream, opts)

    {result, access}
  end

  defp mapping_options(opts, route, operation, true) do
    opts
    |> Keyword.put(:response_stream_mapper, {Mapper, {route, operation}})
    |> Keyword.put(:on_proxy_error, &proxy_error(&1, &2, route, operation))
  end

  defp mapping_options(opts, route, operation, false) do
    previous = opts[:map_response_body]

    opts
    |> Keyword.put(:map_response_body, fn status, headers, body ->
      Mapper.body(route, operation, previous, status, headers, body)
    end)
    |> Keyword.put(:on_proxy_error, &proxy_error(&1, &2, route, operation))
  end

  defp proxy_error(conn, {:response_stream_mapper, code}, route, :create) do
    _ = ResponseRoute.uncertain(route)
    conn |> put_resp_header("x-should-retry", "false") |> error(code)
  end

  defp proxy_error(conn, _reason, route, :create) do
    _ = ResponseRoute.uncertain(route)
    conn |> put_resp_header("x-should-retry", "false") |> error(:response_outcome_uncertain)
  end

  defp proxy_error(conn, _reason, _route, _operation), do: error(conn, :response_transport_error)

  defp reconcile_attempt(route, conn) do
    cond do
      conn.private[:relayixir_proxy_error] || conn.private[:relayixir_downstream_disconnected] ->
        ResponseRoute.uncertain(route)

      conn.status not in 200..299 ->
        ResponseRoute.mark(route, "failed")

      true ->
        :ok
    end
  end

  defp stream_body?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => true}} -> true
      _ -> false
    end
  end

  defp stream_body?(_), do: false

  defp stream_query?(query) do
    URI.decode_query(query)["stream"] == "true"
  rescue
    ArgumentError -> false
  end

  defp strip_authentication(conn) do
    Enum.reduce(
      ~w(authorization x-api-key api-key x-goog-api-key cookie proxy-authorization),
      conn,
      &delete_req_header(&2, &1)
    )
  end

  defp validate_request_context(conn) do
    if Enum.any?(~w(openai-project openai-organization), &(get_req_header(conn, &1) != [])),
      do: {:error, :response_scope_header_unsupported},
      else: :ok
  end

  defp outcome(%{private: %{relayixir_downstream_disconnected: true}}), do: :cancelled
  defp outcome(%{status: status}) when status in 200..299, do: :success
  defp outcome(_), do: :error

  @doc false
  def error(conn, code) do
    {status, message} = error_description(code)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{error: %{code: code, message: message, type: "responses_lifecycle_error"}})
    )
  end

  defp error_description(:responses_identity_required),
    do: {401, "Responses lifecycle requires an authenticated client identity"}

  defp error_description(:responses_lifecycle_unsupported),
    do: {422, "Provider is not enabled and verified for native Responses lifecycle APIs"}

  defp error_description(:response_not_found),
    do:
      {404,
       "No owned Responses route exists; untracked or unsupported provider responses cannot be recovered"}

  defp error_description(:invalid_response_id), do: {400, "Invalid response ID"}
  defp error_description(:response_expired), do: {410, "Responses route has expired"}

  defp error_description(:response_route_changed),
    do: {409, "Original provider, API or credential context has changed"}

  defp error_description(:response_id_conflict),
    do: {409, "Response ID conflicts with an existing owned route"}

  defp error_description(:response_scope_header_unsupported),
    do:
      {422,
       "Configure OpenAI project/organization on the provider; request-local scope overrides cannot be recovered safely"}

  defp error_description(:responses_encoding_unsupported),
    do: {502, "Recoverable Responses require an identity-encoded upstream response"}

  defp error_description(:rate_limited), do: {429, "Provider rate limit exceeded"}

  defp error_description(:response_outcome_uncertain),
    do: {502, "Submission outcome is uncertain; do not automatically resubmit generation"}

  defp error_description(:response_transport_error),
    do: {502, "Lifecycle transport interrupted; query the same response to reconcile its status"}

  defp error_description(_), do: {503, "Responses index or provider credential unavailable"}
end
