defmodule Backplane.LLM.OpenAICodexProxyPlug do
  @moduledoc """
  Transparent provider-scoped proxy for the OpenAI Codex Responses API.

  Requests are dispatched before JSON parsing. Request bytes, query strings,
  response bodies, SSE frames, and upstream errors are forwarded unchanged.
  """

  @behaviour Plug

  import Ecto.Query
  import Plug.Conn

  alias Backplane.LLM.{
    CredentialPlug,
    OpenAICodex,
    Provider,
    ProviderApi,
    RateLimiter,
    RequestAuthorizationPlug
  }

  alias Relayixir.Proxy.{HttpPlug, Upstream}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    conn
    |> RequestAuthorizationPlug.call([])
    |> dispatch()
  end

  defp dispatch(%Plug.Conn{halted: true} = conn), do: conn

  defp dispatch(%Plug.Conn{path_info: ["v1", "providers", provider_name | rest]} = conn) do
    start_ms = System.monotonic_time(:millisecond)

    case fetch_provider(provider_name) do
      {:ok, provider} ->
        dispatch_provider(conn, provider, rest, start_ms)

      {:error, reason} ->
        send_local_failure(
          conn,
          reason,
          %{provider_name: provider_name, endpoint: Enum.join(rest, "/")},
          start_ms
        )
    end
  end

  defp dispatch_provider(conn, provider, rest, start_ms) do
    telemetry_started(conn, provider, rest)

    with :ok <- validate_provider_state(provider),
         {:ok, provider_api} <- fetch_provider_api(provider),
         :ok <- validate_provider_kind(provider),
         {:ok, upstream_path} <- upstream_path(conn.method, rest),
         :ok <- RateLimiter.check(provider.id, provider.rpm_limit) do
      proxy(conn, provider, provider_api, upstream_path, start_ms)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        send_rate_limit_failure(conn, provider, rest, retry_after, start_ms)

      {:error, reason} ->
        send_local_failure(
          conn,
          reason,
          %{
            provider_id: provider.id,
            provider_name: provider.name,
            endpoint: Enum.join(rest, "/")
          },
          start_ms
        )
    end
  end

  defp fetch_provider(name) do
    case Provider
         |> where([p], p.name == ^name)
         |> Backplane.Repo.one() do
      %Provider{} = provider -> {:ok, provider}
      nil -> {:error, :provider_not_found}
    end
  end

  defp validate_provider_state(%Provider{deleted_at: deleted_at}) when not is_nil(deleted_at),
    do: {:error, :provider_not_found}

  defp validate_provider_state(%Provider{enabled: false}), do: {:error, :provider_disabled}
  defp validate_provider_state(%Provider{}), do: :ok

  defp validate_provider_kind(%Provider{preset_key: "openai-codex"}), do: :ok
  defp validate_provider_kind(%Provider{}), do: {:error, :unsupported_provider}

  defp fetch_provider_api(%Provider{} = provider) do
    case ProviderApi.list_for_provider(provider.id)
         |> Enum.find(&(&1.api_surface == :openai and &1.enabled)) do
      %ProviderApi{} = api -> {:ok, api}
      nil -> {:error, :api_surface_disabled}
    end
  end

  defp upstream_path("GET", ["models"]), do: {:ok, ["models"]}
  defp upstream_path("POST", ["responses"]), do: {:ok, ["responses"]}
  defp upstream_path("POST", ["responses", "compact"]), do: {:ok, ["responses", "compact"]}
  defp upstream_path(_method, _path), do: {:error, :unsupported_endpoint}

  defp proxy(conn, provider, provider_api, upstream_path, start_ms) do
    with {:ok, token, meta} <- fetch_credential(provider),
         :ok <- validate_metadata(meta),
         {:ok, backend_base_url} <- validate_backend_base_url(provider_api.base_url),
         {replace_headers, default_headers} =
           CredentialPlug.codex_headers(token, meta, provider.default_headers),
         upstream = build_upstream(backend_base_url, replace_headers, default_headers),
         conn = put_upstream_path(conn, upstream_path) do
      result = HttpPlug.call(conn, upstream, [])

      cond do
        client_disconnected?(result) ->
          telemetry_failed(
            result,
            %{
              provider_id: provider.id,
              provider_name: provider.name,
              endpoint: Enum.join(upstream_path, "/"),
              error_class: :client_disconnected
            },
            %{latency_ms: System.monotonic_time(:millisecond) - start_ms}
          )

        transport_error?(result) ->
          telemetry_failed(
            result,
            %{
              provider_id: provider.id,
              provider_name: provider.name,
              endpoint: Enum.join(upstream_path, "/"),
              error_class: :upstream_transport_error
            },
            %{latency_ms: System.monotonic_time(:millisecond) - start_ms}
          )

        true ->
          telemetry_completed(provider, upstream_path, result, start_ms)
      end

      result
    else
      {:error, :unsupported_endpoint} ->
        send_local_failure(
          conn,
          :unsupported_endpoint,
          %{
            provider_id: provider.id,
            provider_name: provider.name,
            endpoint: Enum.join(upstream_path, "/")
          },
          start_ms
        )

      {:error, reason} ->
        send_local_failure(
          conn,
          reason,
          %{
            provider_id: provider.id,
            provider_name: provider.name,
            endpoint: Enum.join(upstream_path, "/")
          },
          start_ms
        )
    end
  end

  defp put_upstream_path(conn, path_info) do
    %{
      conn
      | path_info: path_info,
        request_path: "/" <> Enum.join(path_info, "/")
    }
  end

  defp fetch_credential(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    case Backplane.Settings.Credentials.fetch_with_meta(credential) do
      {:ok, token, meta} -> {:ok, token, meta}
      {:error, reason} -> {:error, credential_error(reason)}
    end
  end

  defp fetch_credential(_provider), do: {:error, :credential_unavailable}

  defp validate_metadata(%{auth_type: "openai_oauth"}), do: :ok
  defp validate_metadata(_meta), do: {:error, :credential_metadata_invalid}

  defp validate_backend_base_url(base_url) do
    case OpenAICodex.validate_backend_base_url(base_url) do
      {:ok, backend_url} -> {:ok, backend_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_error(:not_found), do: :credential_unavailable
  defp credential_error(:unrecognized_format), do: :credential_metadata_invalid
  defp credential_error(:invalid_json), do: :credential_metadata_invalid
  defp credential_error(:missing_access_token), do: :credential_unavailable
  defp credential_error(:missing_refresh_token), do: :oauth_refresh_failed
  defp credential_error(_reason), do: :oauth_refresh_failed

  defp build_upstream(backend_base_url, replace_headers, default_headers) do
    uri = URI.parse(backend_base_url)

    %Upstream{
      scheme: String.to_existing_atom(uri.scheme || "https"),
      host: uri.host,
      port: uri.port || 443,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      connect_timeout: 10_000,
      max_request_body_size: 50_000_000,
      max_response_body_size: 50_000_000,
      pool_size: 4,
      path_prefix_rewrite: normalize_path_prefix(uri.path),
      inject_request_headers: replace_headers,
      default_request_headers: default_headers,
      proxy: :environment,
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{api_surface: :openai, provider_kind: :openai_codex}
    }
  end

  defp normalize_path_prefix(nil), do: ""
  defp normalize_path_prefix(path), do: String.trim_trailing(path, "/")

  defp send_local_error(conn, :unsupported_endpoint),
    do: send_json(conn, 404, :unsupported_endpoint)

  defp send_local_error(conn, :provider_not_found), do: send_json(conn, 404, :provider_not_found)

  defp send_local_error(conn, :provider_disabled), do: send_json(conn, 503, :provider_disabled)

  defp send_local_error(conn, :api_surface_disabled),
    do: send_json(conn, 503, :api_surface_disabled)

  defp send_local_error(conn, :unsupported_provider),
    do: send_json(conn, 503, :unsupported_provider)

  defp send_local_error(conn, :invalid_model_list), do: send_json(conn, 502, :invalid_model_list)

  defp send_local_error(conn, reason), do: send_json(conn, 503, reason)

  defp send_rate_limit_error(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        "error" => %{
          "message" => "Provider rate limit exceeded. Retry after #{retry_after} seconds.",
          "type" => "rate_limit_error",
          "code" => "rate_limit_exceeded"
        }
      })
    )
    |> halt()
  end

  defp send_rate_limit_failure(conn, provider, path, retry_after, start_ms) do
    conn = send_rate_limit_error(conn, retry_after)

    telemetry_failed(
      conn,
      %{
        provider_id: provider.id,
        provider_name: provider.name,
        endpoint: Enum.join(path, "/"),
        error_class: :provider_rate_limited
      },
      %{latency_ms: elapsed_ms(start_ms)}
    )

    conn
  end

  defp send_local_failure(conn, reason, metadata, start_ms) do
    conn = send_local_error(conn, reason)

    metadata = Map.put(metadata, :error_class, reason)
    telemetry_failed(conn, metadata, %{latency_ms: elapsed_ms(start_ms)})

    conn
  end

  defp send_json(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => %{"code" => Atom.to_string(code)}}))
    |> halt()
  end

  defp telemetry_started(conn, provider, path) do
    :telemetry.execute([:backplane, :codex, :proxy, :request, :started], %{}, %{
      provider_id: provider.id,
      provider_name: provider.name,
      endpoint: Enum.join(path, "/"),
      method: conn.method,
      status: nil,
      stream: request_stream?(conn),
      client_request_id: request_header_value(conn, "x-client-request-id"),
      upstream_request_id: nil,
      error_class: nil
    })
  end

  defp telemetry_completed(provider, path, conn, start_ms) do
    :telemetry.execute(
      [:backplane, :codex, :proxy, :request, :completed],
      %{latency_ms: elapsed_ms(start_ms)},
      %{
        provider_id: provider.id,
        provider_name: provider.name,
        endpoint: Enum.join(path, "/"),
        method: conn.method,
        status: conn.status,
        stream: sse_response?(conn),
        client_request_id: request_header_value(conn, "x-client-request-id"),
        upstream_request_id: upstream_request_id(conn),
        error_class: upstream_error_class(conn.status, path)
      }
    )
  end

  defp telemetry_failed(conn, metadata, measurements) do
    event_metadata = %{
      provider_id: Map.get(metadata, :provider_id),
      provider_name: Map.get(metadata, :provider_name),
      endpoint: Map.get(metadata, :endpoint),
      method: conn.method,
      status: conn.status,
      stream: sse_response?(conn),
      error_class: Map.get(metadata, :error_class),
      client_request_id: request_header_value(conn, "x-client-request-id"),
      upstream_request_id: upstream_request_id(conn)
    }

    :telemetry.execute(
      [:backplane, :codex, :proxy, :request, :failed],
      measurements,
      event_metadata
    )
  end

  defp transport_error?(conn) do
    not is_nil(conn.private[:relayixir_proxy_error])
  end

  defp client_disconnected?(conn), do: conn.private[:relayixir_downstream_disconnected] == true

  defp elapsed_ms(start_ms), do: System.monotonic_time(:millisecond) - start_ms

  defp upstream_error_class(401, _path), do: :upstream_unauthorized
  defp upstream_error_class(403, _path), do: :upstream_forbidden
  defp upstream_error_class(404, ["responses"]), do: :upstream_model_unavailable
  defp upstream_error_class(429, _path), do: :upstream_rate_limited
  defp upstream_error_class(_status, _path), do: nil

  defp request_stream?(conn) do
    conn
    |> request_header_value("accept")
    |> case do
      nil -> false
      accept -> String.contains?(String.downcase(accept), "text/event-stream")
    end
  end

  defp sse_response?(conn) do
    conn.resp_headers
    |> Enum.find_value(fn
      {"content-type", value} -> value
      _ -> nil
    end)
    |> case do
      nil -> ""
      value -> value
    end
    |> String.contains?("text/event-stream")
  end

  defp upstream_request_id(conn) do
    Enum.find_value(["x-request-id", "request-id", "openai-request-id"], fn header ->
      response_header_value(conn, header)
    end)
  end

  defp request_header_value(conn, header), do: header_value(conn.req_headers, header)
  defp response_header_value(conn, header), do: header_value(conn.resp_headers, header)

  defp header_value(headers, header) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == header, do: value
    end)
  end
end
