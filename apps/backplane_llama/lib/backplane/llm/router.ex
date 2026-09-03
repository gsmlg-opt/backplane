defmodule Backplane.LLM.Router do
  @moduledoc """
  Plug.Router that handles LLM proxy requests.

  Aggregates LLM providers behind a single OpenAI/Anthropic-compatible endpoint.
  Routes:
  - GET  /v1                           — protected-resource descriptor
  - GET  /v1/models                    — aggregated model listing
  - POST /v1/messages                  — Anthropic Messages API
  - POST /v1/embeddings                — OpenAI-compatible Embeddings API
  - POST /v1/chat/completions          — OpenAI Chat Completions API
  - POST /v1/responses                 — OpenAI Responses API
  - POST _                             — catch-all forwarded as :openai
  """

  use Plug.Router

  require Logger

  import Plug.Conn

  alias Backplane.LLM.{
    AccessEvent,
    AutoModel,
    CredentialPlug,
    ModelAlias,
    ModelExtractor,
    ModelResolver,
    MoonshotCompat,
    OpenAICodexCompat,
    Provider,
    ProviderApi,
    RateLimiter
  }

  alias Backplane.Embedding
  alias Backplane.Transport.CacheBodyReader
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  plug(Backplane.Transport.CORS)
  plug(:match)

  plug(Backplane.Auth.ResourceAuthPlug,
    resource: :v1,
    required_scope: {Backplane.LLM.ResourceAuthorization, :required_scope, []}
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

  # ── Routes ────────────────────────────────────────────────────────────────────

  get "/v1" do
    send_json(conn, 200, %{
      "resource" => Backplane.Auth.Resources.uri(:v1),
      "resource_documentation" => Backplane.Auth.Resources.documentation_uri(:v1)
    })
  end

  get "/v1/models" do
    models = build_model_list()
    send_json(conn, 200, %{"object" => "list", "data" => models})
  end

  post "/v1/messages" do
    proxy_request(conn, :anthropic)
  end

  post "/v1/embeddings" do
    proxy_embedding_request(conn)
  end

  post "/v1/chat/completions" do
    proxy_request(conn, :openai)
  end

  post "/v1/responses" do
    proxy_request(conn, :openai)
  end

  post _ do
    proxy_request(conn, :openai)
  end

  match _ do
    send_json(conn, 404, %{
      "type" => "error",
      "error" => %{"type" => "not_found_error", "message" => "Route not found"}
    })
  end

  # ── Proxy dispatch ────────────────────────────────────────────────────────────

  defp strip_repeated_request_prefix(%Plug.Conn{} = conn, prefix) do
    stripped = Enum.drop_while(conn.path_info, &(&1 == prefix))

    if stripped == conn.path_info do
      conn
    else
      put_request_path(conn, stripped)
    end
  end

  defp put_request_path(conn, path_info) do
    conn
    |> Map.put(:path_info, path_info)
    |> Map.put(:request_path, "/" <> Enum.join(path_info, "/"))
  end

  defp proxy_request(conn, api_type) do
    access = AccessEvent.start(conn, operation_for_path(conn.request_path), api_type)
    raw_body = conn.assigns[:raw_body] || ""

    case ModelExtractor.extract(raw_body) do
      {:error, reason} ->
        conn = send_model_error(conn, api_type, reason)

        finalize_access(access, conn, :error,
          error_kind: :validation,
          error_code: error_code_for_model_error(reason),
          error_reason: reason
        )

        conn

      {:ok, model_string} ->
        access = AccessEvent.put_requested_model(access, model_string)

        with {:ok, provider, raw_model} <- ModelResolver.resolve(api_type, model_string),
             {:ok, provider_api} <- fetch_provider_api(provider, api_type),
             :ok <- RateLimiter.check(provider.id, provider.rpm_limit),
             {:ok, rewritten_body} <- ModelExtractor.replace_model(raw_body, raw_model),
             {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, api_type),
             {:ok, rewritten_body} <-
               MoonshotCompat.normalize_request_body(
                 provider,
                 provider_api,
                 raw_model,
                 rewritten_body
               ) do
          access =
            AccessEvent.put_resolution(access, provider, raw_model, provider_api)

          codex_backend? = OpenAICodexCompat.enabled?(provider, provider_api)
          provider_api = OpenAICodexCompat.effective_api(provider_api, codex_backend?)

          if codex_backend? and OpenAICodexCompat.chat_completions_request?(conn) do
            proxy_codex_chat_completion(
              conn,
              provider_api,
              auth_headers,
              provider,
              raw_model,
              rewritten_body,
              api_type,
              access
            )
          else
            conn = upstream_request_conn(conn, api_type, provider_api, codex_backend?)
            upstream = build_upstream(provider_api, auth_headers)
            do_proxy(conn, upstream, provider, raw_model, rewritten_body, api_type, access)
          end
        else
          {:error, :no_provider} ->
            conn = send_not_found(conn, api_type, model_string)

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "model_not_found",
              error_reason: :no_provider
            )

            conn

          {:error, :api_type_mismatch, provider} ->
            conn = send_api_type_mismatch(conn, api_type, model_string, provider)

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "api_type_mismatch",
              error_reason: :api_type_mismatch,
              provider: provider
            )

            conn

          {:error, retry_after} when is_integer(retry_after) ->
            conn = send_rate_limit_error(conn, api_type, retry_after)

            finalize_access(access, conn, :error,
              error_kind: :rate_limit,
              error_code: "rate_limit_exceeded",
              error_reason: "rate_limited"
            )

            conn

          {:error, :invalid_json} ->
            conn = send_model_error(conn, api_type, :invalid_json)

            finalize_access(access, conn, :error,
              error_kind: :validation,
              error_code: "invalid_json",
              error_reason: :invalid_json
            )

            conn

          {:error, _} ->
            conn = send_error(conn, api_type, 503, "Provider credential not configured")

            finalize_access(access, conn, :error,
              error_kind: :auth,
              error_code: "credential_missing",
              error_reason: "credential_missing"
            )

            conn
        end
    end
  end

  defp proxy_embedding_request(conn) do
    access = AccessEvent.start(conn, "embeddings", :openai)
    raw_body = conn.assigns[:raw_body] || ""

    case ModelExtractor.extract(raw_body) do
      {:error, reason} ->
        conn = send_model_error(conn, :openai, reason)

        finalize_access(access, conn, :error,
          error_kind: :validation,
          error_code: error_code_for_model_error(reason),
          error_reason: reason
        )

        conn

      {:ok, model_string} ->
        access = AccessEvent.put_requested_model(access, model_string)

        with {:ok, provider, raw_model} <- Embedding.resolve_model(model_string),
             {:ok, rewritten_body} <- ModelExtractor.replace_model(raw_body, raw_model),
             {:ok, auth_headers} <- Embedding.build_auth_headers(provider) do
          access =
            AccessEvent.put_resolution(access, provider, raw_model, nil)

          upstream = build_embedding_upstream(provider, auth_headers)
          do_embedding_proxy(conn, upstream, rewritten_body, access)
        else
          {:error, :no_provider} ->
            conn = send_not_found(conn, :openai, model_string)

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "model_not_found",
              error_reason: :no_provider
            )

            conn

          {:error, :invalid_json} ->
            conn = send_model_error(conn, :openai, :invalid_json)

            finalize_access(access, conn, :error,
              error_kind: :validation,
              error_code: "invalid_json",
              error_reason: :invalid_json
            )

            conn

          {:error, _} ->
            conn = send_error(conn, :openai, 503, "Provider credential not configured")

            finalize_access(access, conn, :error,
              error_kind: :auth,
              error_code: "credential_missing",
              error_reason: "credential_missing"
            )

            conn
        end
    end
  end

  defp fetch_provider_api(%Provider{} = provider, api_type) do
    case Enum.find(
           ProviderApi.list_for_provider(provider.id),
           &(&1.api_surface == api_type and &1.enabled)
         ) do
      %ProviderApi{} = provider_api -> {:ok, provider_api}
      nil -> {:error, :no_provider}
    end
  end

  defp upstream_request_conn(conn, _api_type, _provider_api, true) do
    OpenAICodexCompat.rewrite_conn_path(conn, true)
  end

  defp upstream_request_conn(conn, :openai, %ProviderApi{} = provider_api, false) do
    if base_url_has_path?(provider_api.base_url) do
      strip_repeated_request_prefix(conn, "v1")
    else
      conn
    end
  end

  defp upstream_request_conn(conn, _api_type, _provider_api, _codex_backend?), do: conn

  defp base_url_has_path?(base_url) do
    case URI.parse(base_url).path do
      nil -> false
      "" -> false
      "/" -> false
      _path -> true
    end
  end

  defp build_upstream(%ProviderApi{} = provider_api, auth_headers) do
    uri = URI.parse(provider_api.base_url)

    path_prefix =
      case uri.path do
        nil -> nil
        "/" -> nil
        "" -> nil
        path -> String.trim_trailing(path, "/")
      end

    %Upstream{
      scheme: String.to_existing_atom(uri.scheme || "https"),
      host: uri.host,
      port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path_prefix_rewrite: path_prefix,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      connect_timeout: 10_000,
      max_request_body_size: 50_000_000,
      max_response_body_size: 50_000_000,
      inject_request_headers: auth_headers,
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{provider_api_id: provider_api.id, api_surface: provider_api.api_surface}
    }
  end

  defp build_embedding_upstream(%Embedding.Provider{} = provider, auth_headers) do
    uri = URI.parse(provider.base_url)

    path_prefix =
      case uri.path do
        nil -> nil
        "/" -> nil
        "" -> nil
        path -> String.trim_trailing(path, "/")
      end

    %Upstream{
      scheme: String.to_existing_atom(uri.scheme || "https"),
      host: uri.host,
      port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path_prefix_rewrite: path_prefix,
      request_timeout: 300_000,
      first_byte_timeout: 120_000,
      connect_timeout: 10_000,
      max_request_body_size: 50_000_000,
      max_response_body_size: 50_000_000,
      inject_request_headers: auth_headers,
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{embedding_provider_id: provider.id}
    }
  end

  defp proxy_codex_chat_completion(
         conn,
         provider_api,
         auth_headers,
         provider,
         raw_model,
         rewritten_body,
         api_type,
         access
       ) do
    with {:ok, responses_body} <-
           OpenAICodexCompat.chat_completions_to_responses_body(rewritten_body) do
      conn = OpenAICodexCompat.responses_conn(conn)
      upstream = build_upstream(provider_api, auth_headers)
      stream? = is_stream_request?(responses_body)
      {chunk_mapper, cleanup_mapper} = OpenAICodexCompat.chat_completion_stream_mapper(raw_model)

      extra_opts =
        if stream? do
          [map_response_chunk: chunk_mapper]
        else
          [
            map_response_body: fn body ->
              OpenAICodexCompat.response_body_to_chat_completion(body, raw_model)
            end
          ]
        end

      try do
        do_proxy(conn, upstream, provider, raw_model, responses_body, api_type, access, extra_opts)
      after
        cleanup_mapper.()
      end
    else
      {:error, reason} ->
        conn = send_model_error(conn, api_type, reason)

        finalize_access(access, conn, :error,
          error_kind: :validation,
          error_code: error_code_for_model_error(reason),
          error_reason: reason
        )

        conn
    end
  end

  defp do_proxy(conn, upstream, provider, raw_model, rewritten_body, api_type, access, extra_opts \\ []) do
    stream? = is_stream_request?(rewritten_body)

    access =
      access
      |> AccessEvent.put_resolution(provider, raw_model, provider_api_from_upstream(upstream))
      |> then(fn acc -> if stream?, do: AccessEvent.mark_stream(acc), else: acc end)
      |> AccessEvent.mark_upstream_start()

    on_chunk =
      if stream? do
        fn chunk -> AccessEvent.scan_stream_chunk(access, chunk) end
      end

    opts =
      [body: rewritten_body]
      |> then(fn o -> if on_chunk, do: Keyword.put(o, :on_response_chunk, on_chunk), else: o end)
      |> Keyword.merge(extra_opts)

    conn =
      conn
      |> delete_req_header("authorization")
      |> delete_req_header("x-api-key")

    result_conn = HttpPlug.call(conn, upstream, opts)

    finalize_access(access, result_conn, outcome_for_status(result_conn.status),
      api_surface: api_type,
      status: result_conn.status
    )

    result_conn
  end

  defp do_embedding_proxy(conn, upstream, rewritten_body, access) do
    access = AccessEvent.mark_upstream_start(access)

    conn =
      conn
      |> delete_req_header("authorization")
      |> delete_req_header("x-api-key")

    result_conn = HttpPlug.call(conn, upstream, body: rewritten_body)

    finalize_access(access, result_conn, outcome_for_status(result_conn.status),
      api_surface: :openai,
      status: result_conn.status
    )

    result_conn
  end

  defp is_stream_request?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => true}} -> true
      _ -> false
    end
  end

  defp operation_for_path("/v1/messages"), do: "messages"
  defp operation_for_path("/v1/chat/completions"), do: "chat_completions"
  defp operation_for_path("/v1/responses"), do: "responses"
  defp operation_for_path("/v1/embeddings"), do: "embeddings"
  defp operation_for_path(_), do: "proxy"

  defp outcome_for_status(status) when status in 200..299, do: :success
  defp outcome_for_status(_), do: :error

  defp error_code_for_model_error(:no_model), do: "missing_required_parameter"
  defp error_code_for_model_error(:invalid_json), do: "invalid_json"
  defp error_code_for_model_error(reason), do: to_string(reason)

  defp finalize_access(access, conn, outcome, opts) do
    access =
      case Keyword.get(opts, :provider) do
        %Provider{} = provider ->
          AccessEvent.put_resolution(
            access,
            provider,
            access.resolved_model || access.requested_model,
            nil
          )

        _ ->
          access
      end

    status = Keyword.get(opts, :status, conn.status)
    AccessEvent.finalize(access, conn, outcome, Keyword.put(opts, :status, status))
  end

  defp provider_api_from_upstream(%Upstream{metadata: %{provider_api_id: id}}) when is_binary(id) do
    %ProviderApi{id: id}
  end

  defp provider_api_from_upstream(_), do: nil

  # ── Model listing ─────────────────────────────────────────────────────────────

  defp build_model_list do
    providers =
      Provider.list()
      |> Enum.filter(& &1.enabled)

    provider_entries =
      for provider <- providers,
          model <- provider.models,
          model.enabled do
        %{
          "id" => "#{provider.name}/#{model.model}",
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name
        }
      end

    auto_model_entries =
      for auto_model <- AutoModel.list_configurations(),
          auto_model.enabled,
          auto_model_available?(auto_model) do
        %{
          "id" => auto_model.name,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    custom_alias_entries =
      for model_alias <- ModelAlias.list(),
          custom_alias_available?(model_alias) do
        %{
          "id" => model_alias.alias,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    provider_entries ++ auto_model_entries ++ custom_alias_entries
  end

  defp custom_alias_available?(%ModelAlias{} = model_alias) do
    Enum.any?([:openai, :anthropic], fn api_type ->
      match?({:ok, _provider, _raw_model}, ModelResolver.resolve(api_type, model_alias.alias))
    end)
  end

  defp auto_model_available?(auto_model) do
    configured_model_ids = AutoModel.configured_model_ids(auto_model.name)

    Enum.any?(auto_model.routes, fn route ->
      route.enabled and
        (AutoModel.available_surfaces_for(route.api_surface, configured_model_ids) != [] or
           Enum.any?(route.targets, fn target ->
             surface = target.provider_model_surface
             model = surface.provider_model
             provider = model.provider
             api = surface.provider_api

             target.enabled and surface.enabled and model.enabled and provider.enabled and
               is_nil(provider.deleted_at) and api.enabled
           end))
    end)
  end

  # ── Error helpers ─────────────────────────────────────────────────────────────

  defp send_rate_limit_error(conn, :anthropic, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_json(429, %{
      "type" => "error",
      "error" => %{
        "type" => "rate_limit_error",
        "message" => "Provider rate limit exceeded. Retry after #{retry_after} seconds."
      }
    })
  end

  defp send_rate_limit_error(conn, _api_type, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_json(429, %{
      "error" => %{
        "message" => "Provider rate limit exceeded. Retry after #{retry_after} seconds.",
        "type" => "rate_limit_error",
        "code" => "rate_limit_exceeded"
      }
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_not_found(conn, :anthropic, model) do
    send_json(conn, 404, %{
      "type" => "error",
      "error" => %{
        "type" => "not_found_error",
        "message" => "Model '#{model}' not found"
      }
    })
  end

  defp send_not_found(conn, :openai, model) do
    send_json(conn, 404, %{
      "error" => %{
        "message" => "The model '#{model}' does not exist",
        "type" => "invalid_request_error",
        "code" => "model_not_found"
      }
    })
  end

  defp send_api_type_mismatch(conn, :anthropic, model, _provider) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "Model '#{model}' is not available via the Anthropic Messages API. Use /v1/chat/completions instead."
      }
    })
  end

  defp send_api_type_mismatch(conn, :openai, model, _provider) do
    send_json(conn, 400, %{
      "error" => %{
        "message" =>
          "Model '#{model}' is not available via the OpenAI Chat Completions API. Use /v1/messages instead.",
        "type" => "invalid_request_error",
        "code" => "api_type_mismatch"
      }
    })
  end

  defp send_model_error(conn, :anthropic, :no_model) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "Missing required field: model"
      }
    })
  end

  defp send_model_error(conn, :openai, :no_model) do
    send_json(conn, 400, %{
      "error" => %{
        "message" => "Missing required field: model",
        "type" => "invalid_request_error",
        "code" => "missing_required_parameter"
      }
    })
  end

  defp send_model_error(conn, :anthropic, :invalid_json) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "Invalid JSON body"
      }
    })
  end

  defp send_model_error(conn, :openai, :invalid_json) do
    send_json(conn, 400, %{
      "error" => %{
        "message" => "Invalid JSON body",
        "type" => "invalid_request_error",
        "code" => "invalid_json"
      }
    })
  end

  defp send_error(conn, :anthropic, status, message) do
    send_json(conn, status, %{
      "type" => "error",
      "error" => %{
        "type" => "api_error",
        "message" => message
      }
    })
  end

  defp send_error(conn, _api_type, status, message) do
    send_json(conn, status, %{
      "error" => %{
        "message" => message,
        "type" => "api_error",
        "code" => "proxy_error"
      }
    })
  end

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      Logger.warning("LLM Router: malformed request body: #{Exception.message(e)}")

      send_resp(
        conn,
        400,
        Jason.encode!(%{
          "error" => %{
            "message" => "Malformed request body",
            "type" => "invalid_request_error",
            "code" => "invalid_json"
          }
        })
      )

    e in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("LLM Router: request body too large: #{Exception.message(e)}")

      send_resp(
        conn,
        413,
        Jason.encode!(%{
          "error" => %{
            "message" => "Request body too large",
            "type" => "invalid_request_error",
            "code" => "request_too_large"
          }
        })
      )
  end
end
