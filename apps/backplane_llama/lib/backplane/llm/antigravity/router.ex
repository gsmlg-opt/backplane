defmodule Backplane.LLM.Antigravity.Router do
  @moduledoc false

  use Plug.Router

  require Logger

  import Ecto.Query
  import Plug.Conn

  alias Backplane.AiProtocol.Antigravity

  alias Backplane.LLM.{
    AccessEvent,
    CredentialPlug,
    ModelAlias,
    ModelResolver,
    ProtocolRoute,
    Provider,
    ProviderApi
  }

  alias Backplane.LLM.RateLimiter
  alias Backplane.LLM.Antigravity.{RequestAuthPlug, RequestTarget}
  alias Backplane.LLM.Google.Error
  alias Backplane.Repo
  alias Backplane.Transport.CacheBodyReader
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  @provider_owned_headers [
    "authorization",
    "x-api-key",
    "api-key",
    "x-goog-api-key",
    "cookie",
    "proxy-authorization",
    "x-goog-user-project",
    "x-machine-session-id",
    "x-client-name",
    "x-client-version",
    "user-agent"
  ]

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
      {:ok, target} -> proxy_operation(conn, target)
      {:error, reason} -> target_error(conn, reason)
    end
  end

  defp proxy_operation(conn, target) do
    with {:ok, provider, api} <- provider_binding(target.provider_name),
         {:ok, :native} <- ProtocolRoute.select(:google_antigravity, api),
         :ok <- check_rate_limit(provider),
         {:ok, body} <- native_body(conn),
         :ok <- reject_project_override(target.operation, body),
         {:ok, raw_model, model_opts} <- resolve_model(provider, api, target.operation, body),
         {:ok, request} <- build_request(target.operation, body, api, model_opts),
         {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, :antigravity) do
      do_proxy(conn, target, provider, api, raw_model, request, auth_headers)
    else
      {:error, :no_provider} ->
        Error.send(conn, 404, "Antigravity provider was not found")

      {:error, :model_not_found} ->
        Error.send(conn, 404, "Antigravity model was not found")

      {:error, :project_override} ->
        Error.send(conn, 400, "Antigravity project is managed by the provider configuration")

      {:error, :invalid_json} ->
        Error.send(conn, 400, "Invalid JSON request body")

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> Error.send(429, "Provider rate limit exceeded")

      {:error, {:unsupported_translation, _, _}} ->
        Error.send(conn, 422, "Selected provider does not expose Antigravity natively")

      {:error, %Backplane.AiProtocol.Error{message: message}} ->
        Error.send(conn, 400, message)

      {:error, _reason} ->
        Error.send(conn, 503, "Provider credential is not configured")
    end
  end

  defp provider_binding(provider_name) do
    provider =
      Provider
      |> where([provider], provider.name == ^provider_name)
      |> where([provider], provider.enabled == true and is_nil(provider.deleted_at))
      |> Repo.one()

    with %Provider{} = provider <- provider,
         %ProviderApi{} = api <-
           Repo.get_by(ProviderApi,
             provider_id: provider.id,
             api_surface: :antigravity,
             enabled: true
           ) do
      {:ok, provider, api}
    else
      _ -> {:error, :no_provider}
    end
  end

  defp native_body(%Plug.Conn{body_params: body}) when is_map(body), do: {:ok, body}
  defp native_body(_conn), do: {:error, :invalid_json}

  defp reject_project_override(operation, body)
       when operation in [:load_code_assist, :onboard_user] do
    metadata = body["metadata"]

    if Map.has_key?(body, "project") or
         (is_map(metadata) and Map.has_key?(metadata, "duetProject")),
       do: {:error, :project_override},
       else: :ok
  end

  defp reject_project_override(_operation, body) do
    if Map.has_key?(body, "project"), do: {:error, :project_override}, else: :ok
  end

  defp resolve_model(_provider, _api, operation, _body)
       when operation in [:load_code_assist, :onboard_user, :fetch_available_models],
       do: {:ok, nil, []}

  defp resolve_model(provider, _api, _operation, %{"model" => requested})
       when is_binary(requested) do
    result =
      if ModelAlias.target_for(requested) do
        ModelResolver.resolve(:antigravity, requested)
      else
        case ModelResolver.resolve(:antigravity, "#{provider.name}/#{requested}") do
          {:ok, _, _} = resolved -> resolved
          _ -> ModelResolver.resolve(:antigravity, requested)
        end
      end

    case result do
      {:ok, %{id: provider_id}, raw_model} when provider_id == provider.id ->
        {:ok, raw_model, [model: raw_model]}

      _ ->
        {:error, :model_not_found}
    end
  end

  defp resolve_model(_provider, _api, _operation, _body), do: {:error, :model_not_found}

  defp build_request(operation, body, api, model_opts) do
    config = api.backend_config || %{}
    body = put_generated_ids(operation, body)
    body = if model_opts[:model], do: Map.put(body, "model", model_opts[:model]), else: body

    opts =
      model_opts ++
        [
          project: config["project_id"],
          user_agent: config["user_agent"],
          client_version: config["client_version"]
        ]

    Antigravity.build_request(operation, body, opts)
  end

  defp put_generated_ids(operation, body)
       when operation in [:generate_content, :stream_generate_content] do
    request = body["request"]

    if is_map(request) do
      body
      |> Map.put("request", Map.put_new(request, "sessionId", Ecto.UUID.generate()))
      |> Map.put_new("requestId", "agent-" <> Ecto.UUID.generate())
    else
      body
    end
  end

  defp put_generated_ids(_operation, body), do: body

  defp do_proxy(conn, target, provider, api, raw_model, request, auth_headers) do
    access =
      conn
      |> AccessEvent.start(Atom.to_string(target.operation), :google_antigravity)
      |> AccessEvent.put_requested_model(if(raw_model, do: conn.body_params["model"]))
      |> AccessEvent.put_resolution(provider, raw_model, api)
      |> prepare_observation(target.operation)
      |> AccessEvent.mark_upstream_start()

    observer =
      if AccessEvent.response_observation?(access),
        do: fn chunk -> AccessEvent.scan_stream_chunk(access, chunk) end

    opts =
      [body: Jason.encode!(request.body), on_proxy_error: &Error.proxy/2]
      |> maybe_put_observers(observer)

    conn =
      conn
      |> put_upstream_target(request)
      |> strip_provider_headers()

    headers = trusted_headers(auth_headers, request.headers)
    result = proxy_module().call(conn, build_upstream(api, headers), opts)
    AccessEvent.finalize(access, result, outcome(result), status: result.status)
    result
  end

  defp prepare_observation(access, :stream_generate_content), do: AccessEvent.mark_stream(access)

  defp prepare_observation(access, :generate_content),
    do: AccessEvent.prepare_response_observation(access)

  defp prepare_observation(access, _operation), do: access

  defp maybe_put_observers(opts, nil), do: opts

  defp maybe_put_observers(opts, observer),
    do:
      opts
      |> Keyword.put(:on_response_chunk, observer)
      |> Keyword.put(:on_response_body, observer)

  defp put_upstream_target(conn, request) do
    %{
      conn
      | path_info: String.split(request.path, "/", trim: true),
        request_path: request.path,
        query_string: request.query
    }
  end

  defp strip_provider_headers(conn),
    do: Enum.reduce(@provider_owned_headers, conn, &delete_req_header(&2, &1))

  defp build_upstream(api, headers) do
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
      inject_request_headers: headers,
      default_request_headers: safe_default_headers(api.default_headers),
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{provider_api_id: api.id, api_surface: :antigravity}
    }
  end

  defp safe_default_headers(headers) when is_map(headers) do
    headers
    |> Enum.reject(fn {name, _value} ->
      String.downcase(to_string(name)) in @provider_owned_headers
    end)
    |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  end

  defp safe_default_headers(_headers), do: []

  defp trusted_headers(auth_headers, protocol_headers) do
    protocol_names = MapSet.new(Enum.map(protocol_headers, fn {name, _value} -> name end))

    protocol_headers ++
      Enum.reject(auth_headers, fn {name, _value} ->
        MapSet.member?(protocol_names, String.downcase(to_string(name)))
      end)
  end

  defp check_rate_limit(provider) do
    case RateLimiter.check(provider.id, provider.rpm_limit) do
      :ok -> :ok
      {:error, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  defp proxy_module, do: Application.get_env(:backplane_llama, :antigravity_http_proxy, HttpPlug)

  defp outcome(%Plug.Conn{private: %{relayixir_downstream_disconnected: true}}), do: :cancelled
  defp outcome(%Plug.Conn{private: %{relayixir_proxy_error: _reason}}), do: :error
  defp outcome(%Plug.Conn{status: status}) when status in 200..299, do: :success
  defp outcome(_conn), do: :error

  defp target_error(conn, :query_not_allowed),
    do: Error.send(conn, 400, "Query parameters are not accepted on Antigravity routes")

  defp target_error(conn, :invalid_provider),
    do: Error.send(conn, 400, "Invalid Antigravity provider name")

  defp target_error(conn, _reason), do: Error.send(conn, 404, "Unsupported Antigravity API route")

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    _error in Plug.Parsers.ParseError ->
      Logger.warning("Antigravity Router: malformed request body")
      Error.send(conn, 400, "Malformed request body")

    _error in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("Antigravity Router: request body too large")
      Error.send(conn, 413, "Request body too large")
  end
end
