defmodule Backplane.LLM.Google.Router do
  @moduledoc false

  use Plug.Router

  require Logger

  import Plug.Conn

  alias Backplane.LLM.{
    AccessEvent,
    CredentialPlug,
    ModelResolver,
    ProtocolRoute,
    ProviderApi,
    RateLimiter
  }

  alias Backplane.LLM.Google.{Catalog, Error, RequestAuthPlug, RequestBody, RequestTarget}
  alias Backplane.Transport.CacheBodyReader
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  plug(RequestAuthPlug)
  plug(:match)

  plug(Backplane.Auth.ResourceAuthPlug,
    resource: :v1,
    required_scope: {Backplane.LLM.ResourceAuthorization, :required_scope, []},
    error_format: :google
  )

  plug(Backplane.LLM.ResourceAuthorization)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 50_000_000,
    body_reader: {CacheBodyReader, :read_body, []}
  )

  plug(:dispatch)

  match _ do
    case RequestTarget.parse(conn.method, conn.request_path, conn.query_string) do
      {:ok, %{operation: :models_list}} -> list_models(conn)
      {:ok, %{operation: :models_get, model: model}} -> get_model(conn, model)
      {:ok, target} -> proxy_operation(conn, target)
      {:error, reason} -> target_error(conn, reason)
    end
  end

  defp list_models(conn) do
    case Catalog.list(fetch_query_params(conn).query_params) do
      {:ok, body} -> send_json(conn, 200, body)
      {:error, reason} -> target_error(conn, reason)
    end
  end

  defp get_model(conn, model) do
    case Catalog.get(model) do
      {:ok, descriptor} -> send_json(conn, 200, descriptor)
      {:error, :not_found} -> Error.send(conn, 404, "Model '#{model}' was not found")
    end
  end

  defp proxy_operation(conn, target) do
    raw_body = conn.assigns[:raw_body] || ""

    with {:ok, provider, raw_model} <- ModelResolver.resolve(:google, target.model),
         {:ok, raw_model} <- RequestTarget.normalize_model(raw_model),
         {:ok, api} <- provider_api(provider.id),
         {:ok, :native} <- ProtocolRoute.select(:google_generate_content, api),
         :ok <- check_rate_limit(provider),
         {:ok, body} <- RequestBody.prepare(target.operation, raw_body, target.model, raw_model),
         {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, :google) do
      do_proxy(conn, target, provider, api, raw_model, body, auth_headers)
    else
      {:error, :no_provider} ->
        Error.send(conn, 404, "Model '#{target.model}' was not found")

      {:error, :body_model_conflict} ->
        Error.send(conn, 400, "Request body model conflicts with the URL model")

      {:error, :invalid_json} ->
        Error.send(conn, 400, "Invalid JSON request body")

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> Error.send(429, "Provider rate limit exceeded")

      {:error, {:unsupported_translation, _, _}} ->
        Error.send(conn, 422, "Selected provider does not expose Google GenerateContent natively")

      {:error, _reason} ->
        Error.send(conn, 503, "Provider credential is not configured")
    end
  end

  defp do_proxy(conn, target, provider, api, raw_model, body, auth_headers) do
    access =
      conn
      |> AccessEvent.start(operation_name(target.operation), :google_generate_content)
      |> AccessEvent.put_requested_model(target.model)
      |> AccessEvent.put_resolution(provider, raw_model, api)
      |> prepare_observation(target.operation)
      |> AccessEvent.mark_upstream_start()

    observer =
      if AccessEvent.response_observation?(access),
        do: fn chunk -> AccessEvent.scan_stream_chunk(access, chunk) end

    opts =
      [body: body, on_proxy_error: &Error.proxy/2]
      |> maybe_put_observers(observer)

    conn =
      conn
      |> put_upstream_target(target.operation, raw_model)
      |> strip_client_authentication()

    result = proxy_module().call(conn, build_upstream(api, auth_headers), opts)

    AccessEvent.finalize(access, result, outcome(result), status: result.status)

    result
  end

  defp prepare_observation(access, :stream_generate), do: AccessEvent.mark_stream(access)

  defp prepare_observation(access, _operation),
    do: AccessEvent.prepare_response_observation(access)

  defp maybe_put_observers(opts, nil), do: opts

  defp maybe_put_observers(opts, observer) do
    opts
    |> Keyword.put(:on_response_chunk, observer)
    |> Keyword.put(:on_response_body, observer)
  end

  defp provider_api(provider_id) do
    case Enum.find(ProviderApi.list_for_provider(provider_id), fn api ->
           api.enabled and api.api_surface == :google
         end) do
      nil -> {:error, :no_provider}
      api -> {:ok, api}
    end
  end

  defp check_rate_limit(provider) do
    case RateLimiter.check(provider.id, provider.rpm_limit) do
      :ok -> :ok
      {:error, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  defp put_upstream_target(conn, operation, raw_model) do
    {:ok, request_path} = RequestTarget.upstream_path(operation, raw_model)
    %{conn | path_info: String.split(request_path, "/", trim: true), request_path: request_path}
  end

  defp strip_client_authentication(conn) do
    Enum.reduce(
      [
        "authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "cookie",
        "proxy-authorization"
      ],
      conn,
      &delete_req_header(&2, &1)
    )
  end

  defp build_upstream(api, auth_headers) do
    uri = URI.parse(api.base_url)
    path = if uri.path in [nil, "", "/"], do: nil, else: String.trim_trailing(uri.path, "/")

    %Upstream{
      scheme: String.to_existing_atom(uri.scheme || "https"),
      host: uri.host,
      port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path_prefix_rewrite: path,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      connect_timeout: 10_000,
      max_request_body_size: 50_000_000,
      max_response_body_size: 50_000_000,
      proxy: :environment,
      inject_request_headers: auth_headers,
      default_request_headers: safe_api_default_headers(api.default_headers),
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{provider_api_id: api.id, api_surface: :google}
    }
  end

  defp proxy_module do
    Application.get_env(:backplane_llama, :google_http_proxy, HttpPlug)
  end

  defp safe_api_default_headers(headers) when is_map(headers) do
    headers
    |> Enum.reject(fn {name, _value} ->
      String.downcase(to_string(name)) in ["authorization", "x-api-key", "x-goog-api-key"]
    end)
    |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  end

  defp safe_api_default_headers(_headers), do: []

  defp operation_name(:generate), do: "generate"
  defp operation_name(:stream_generate), do: "stream_generate"
  defp operation_name(:count_tokens), do: "count_tokens"

  defp outcome(%Plug.Conn{private: %{relayixir_downstream_disconnected: true}}), do: :cancelled
  defp outcome(%Plug.Conn{private: %{relayixir_proxy_error: _reason}}), do: :error
  defp outcome(%Plug.Conn{status: status}) when status in 200..299, do: :success
  defp outcome(_conn), do: :error

  defp target_error(conn, :invalid_model), do: Error.send(conn, 400, "Invalid model or alias")

  defp target_error(conn, :stream_requires_sse),
    do: Error.send(conn, 400, "streamGenerateContent requires alt=sse")

  defp target_error(conn, :invalid_page_size), do: Error.send(conn, 400, "Invalid pageSize")
  defp target_error(conn, :invalid_page_token), do: Error.send(conn, 400, "Invalid pageToken")

  defp target_error(conn, _reason),
    do: Error.send(conn, 404, "Unsupported Google GenAI API route")

  defp send_json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    _error in Plug.Parsers.ParseError ->
      Logger.warning("Google GenAI Router: malformed request body")
      Error.send(conn, 400, "Malformed request body")

    _error in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("Google GenAI Router: request body too large")
      Error.send(conn, 413, "Request body too large")
  end
end
