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
  - POST _                             — supported repeated-prefix compatibility routes
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
    ModelMetadata,
    ModelResolver,
    Provider,
    ProviderApi,
    ProtocolRoute,
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
    {data, models} = build_model_list()
    send_json(conn, 200, %{"object" => "list", "data" => data, "models" => models})
  end

  post "/v1/messages" do
    proxy_request(conn, :anthropic_messages)
  end

  post "/v1/embeddings" do
    proxy_embedding_request(conn)
  end

  post "/v1/chat/completions" do
    proxy_request(conn, :openai_chat_completions)
  end

  post "/v1/responses" do
    proxy_request(conn, :openai_responses)
  end

  post _ do
    case ProtocolRoute.client_protocol(conn.request_path) do
      :unknown ->
        send_json(conn, 404, %{
          "error" => %{
            "message" => "Unsupported LLM API route",
            "type" => "invalid_request_error",
            "code" => "unsupported_api_route"
          }
        })

      client_protocol ->
        proxy_request(conn, client_protocol)
    end
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

  defp proxy_request(conn, client_protocol) do
    api_type = api_type(client_protocol)
    access = AccessEvent.start(conn, operation_for_path(conn.request_path), client_protocol)
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
             :ok <- reject_codex_chat_completions(conn, provider),
             {:ok, :native} <- ProtocolRoute.select(client_protocol, provider_api),
             :ok <- check_rate_limit(provider),
             {:ok, rewritten_body} <-
               ModelExtractor.replace_model(raw_body, model_string, raw_model),
             {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, api_type) do
          conn = upstream_request_conn(conn, api_type, provider_api)
          upstream = build_upstream(provider_api, auth_headers)

          do_proxy(
            conn,
            upstream,
            provider,
            model_string,
            raw_model,
            rewritten_body,
            client_protocol,
            api_type,
            access
          )
        else
          {:error, :no_provider} ->
            conn = send_not_found(conn, api_type, model_string)

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "model_not_found",
              error_reason: :no_provider
            )

            conn

          {:error, :codex_requires_responses_api} ->
            send_codex_rejection(conn)

          {:error, {:unsupported_translation, requested_protocol, native_protocols}} ->
            conn =
              send_unsupported_translation(
                conn,
                api_type,
                requested_protocol,
                native_protocols
              )

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "unsupported_protocol_translation",
              error_reason: :unsupported_protocol_translation
            )

            conn

          {:error, :api_type_mismatch, provider} ->
            conn = send_api_type_mismatch(conn, client_protocol, model_string, provider)

            finalize_access(access, conn, :error,
              error_kind: :routing,
              error_code: "api_type_mismatch",
              error_reason: :api_type_mismatch,
              provider: provider
            )

            conn

          {:error, :rate_limited, retry_after, provider} ->
            conn = send_rate_limit_error(conn, api_type, retry_after)

            finalize_access(access, conn, :error,
              error_kind: :rate_limit,
              error_code: "rate_limit_exceeded",
              error_reason: "rate_limited",
              provider: provider
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

  defp reject_codex_chat_completions(
         %Plug.Conn{request_path: "/v1/chat/completions"},
         %Provider{preset_key: "openai-codex"}
       ),
       do: {:error, :codex_requires_responses_api}

  defp reject_codex_chat_completions(_conn, _provider), do: :ok

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
             {:ok, rewritten_body} <-
               ModelExtractor.replace_model(raw_body, model_string, raw_model),
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

  defp upstream_request_conn(conn, :openai, %ProviderApi{} = provider_api) do
    if base_url_has_path?(provider_api.base_url) do
      strip_repeated_request_prefix(conn, "v1")
    else
      conn
    end
  end

  defp upstream_request_conn(conn, _api_type, _provider_api), do: conn

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
      proxy: :environment,
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
      proxy: :environment,
      inject_request_headers: auth_headers,
      host_forward_mode: :rewrite_to_upstream,
      metadata: %{embedding_provider_id: provider.id}
    }
  end

  defp do_proxy(
         conn,
         upstream,
         provider,
         requested_model,
         raw_model,
         rewritten_body,
         client_protocol,
         api_type,
         access,
         extra_opts \\ []
       ) do
    stream? = is_stream_request?(rewritten_body)

    access =
      access
      |> AccessEvent.put_resolution(provider, raw_model, provider_api_from_upstream(upstream))
      |> then(fn acc -> if stream?, do: AccessEvent.mark_stream(acc), else: acc end)
      |> AccessEvent.prepare_response_observation()
      |> AccessEvent.mark_upstream_start()

    response_observer =
      if AccessEvent.response_observation?(access) do
        fn chunk -> AccessEvent.scan_stream_chunk(access, chunk) end
      end

    opts =
      [body: rewritten_body]
      |> then(fn opts ->
        if response_observer do
          opts
          |> Keyword.put(:on_response_chunk, response_observer)
          |> Keyword.put(:on_response_body, response_observer)
        else
          opts
        end
      end)
      |> response_model_mapping(client_protocol, requested_model, raw_model, stream?)
      |> Keyword.merge(extra_opts)

    conn = strip_client_authentication(conn)

    result_conn = HttpPlug.call(conn, upstream, opts)

    finalize_access(access, result_conn, outcome_for_conn(result_conn),
      api_surface: api_type,
      status: result_conn.status
    )

    result_conn
  end

  defp response_model_mapping(opts, _client_protocol, model, model, _stream?), do: opts

  defp response_model_mapping(opts, :openai_responses, requested_model, raw_model, true) do
    Keyword.put(
      opts,
      :map_response_chunk,
      Backplane.LLM.ModelResponse.responses_stream_mapper(requested_model, raw_model)
    )
  end

  defp response_model_mapping(opts, :openai_responses, requested_model, raw_model, false) do
    Keyword.put(opts, :map_response_body, fn body ->
      Backplane.LLM.ModelResponse.normalize_responses_body(body, requested_model, raw_model)
    end)
  end

  defp response_model_mapping(opts, _client_protocol, requested_model, raw_model, true) do
    Keyword.put(opts, :map_response_chunk, fn chunk ->
      Backplane.LLM.ModelResponse.normalize_chunk(chunk, requested_model, raw_model)
    end)
  end

  defp response_model_mapping(opts, _client_protocol, requested_model, raw_model, false) do
    Keyword.put(opts, :map_response_body, fn body ->
      Backplane.LLM.ModelResponse.normalize_body(body, requested_model, raw_model)
    end)
  end

  defp do_embedding_proxy(conn, upstream, rewritten_body, access) do
    access = AccessEvent.mark_upstream_start(access)

    conn = strip_client_authentication(conn)

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

  defp api_type(:anthropic_messages), do: :anthropic

  defp api_type(protocol) when protocol in [:openai_chat_completions, :openai_responses],
    do: :openai

  # Client authentication is a Backplane concern. Remove every supported inbound
  # credential carrier before Relayixir injects the selected provider credential.
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

  defp outcome_for_status(status) when status in 200..299, do: :success
  defp outcome_for_status(_), do: :error

  defp outcome_for_conn(%Plug.Conn{private: %{relayixir_downstream_disconnected: true}}),
    do: :cancelled

  defp outcome_for_conn(%Plug.Conn{status: status}), do: outcome_for_status(status)

  defp check_rate_limit(provider) do
    case RateLimiter.check(provider.id, provider.rpm_limit) do
      :ok -> :ok
      {:error, retry_after} -> {:error, :rate_limited, retry_after, provider}
    end
  end

  defp error_code_for_model_error(:no_model), do: "missing_required_parameter"
  defp error_code_for_model_error(:invalid_json), do: "invalid_json"

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

  defp provider_api_from_upstream(%Upstream{metadata: %{provider_api_id: id}})
       when is_binary(id) do
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
          "owned_by" => provider.name,
          "provider" => provider.name,
          "canonical_id" => model.model
        }
      end

    auto_model_entries =
      for auto_model <- AutoModel.list_configurations(),
          auto_model.enabled do
        %{
          "id" => auto_model.name,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    custom_alias_entries =
      for model_alias <- ModelAlias.list() do
        %{
          "id" => model_alias.alias,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    entries =
      (provider_entries ++ auto_model_entries ++ custom_alias_entries)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])

    resolved_entries =
      for entry <- entries,
          target = selected_model_target(providers, entry["id"]),
          not is_nil(target) do
        {provider, model, surface, _api} = target
        raw_metadata = Map.merge(model.metadata || %{}, surface.metadata || %{})
        metadata = ModelMetadata.normalize(provider.preset_key, raw_metadata)
        {Map.put(entry, "metadata", metadata), target}
      end

    models =
      for {{entry, {provider, model, _surface, api}}, priority} <-
            Enum.with_index(resolved_entries),
          api.api_surface == :openai,
          :openai_responses in api.native_protocols,
          provider.preset_key != "openai-codex" do
        ModelMetadata.codex(entry["id"], model.display_name, entry["metadata"],
          supported_in_api: true,
          priority: priority
        )
      end

    {Enum.map(resolved_entries, &elem(&1, 0)), models}
  end

  defp selected_model_target(providers, id) do
    Enum.find_value([:openai, :anthropic], fn api_surface ->
      with {:ok, resolved_provider, raw_model} <- ModelResolver.resolve(api_surface, id),
           %Provider{} = provider <- Enum.find(providers, &(&1.id == resolved_provider.id)),
           %ProviderApi{} = api <-
             Enum.find(provider.apis, &(&1.enabled and &1.api_surface == api_surface)),
           model when not is_nil(model) <-
             Enum.find(provider.models, &(&1.enabled and &1.model == raw_model)),
           surface when not is_nil(surface) <-
             Enum.find(model.surfaces, &(&1.enabled and &1.provider_api_id == api.id)) do
        {provider, model, surface, api}
      else
        _ -> nil
      end
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

  defp send_api_type_mismatch(conn, :anthropic_messages, model, _provider) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "Model '#{model}' is not available via the Anthropic Messages API, and no complete translation route is configured. Use a model with a native Anthropic Messages surface."
      }
    })
  end

  defp send_api_type_mismatch(conn, client_protocol, model, _provider)
       when client_protocol in [:openai_chat_completions, :openai_responses] do
    api_name =
      case client_protocol do
        :openai_chat_completions -> "OpenAI Chat Completions API"
        :openai_responses -> "OpenAI Responses API"
      end

    send_json(conn, 400, %{
      "error" => %{
        "message" =>
          "Model '#{model}' is not available via the #{api_name}, and no complete translation route is configured. Use a model with a native #{api_name} surface.",
        "type" => "invalid_request_error",
        "code" => "api_type_mismatch"
      }
    })
  end

  defp send_codex_rejection(conn) do
    send_json(conn, 400, %{
      "error" => %{
        "type" => "unsupported_api_surface",
        "code" => "codex_requires_responses_api",
        "message" => "OpenAI Codex providers support the Responses API only."
      }
    })
  end

  defp send_unsupported_translation(conn, api_type, requested_protocol, native_protocols) do
    available = native_protocols |> Enum.map_join(", ", &to_string/1)

    message =
      "The selected provider does not expose #{requested_protocol} natively, and Backplane " <>
        "has no complete translation route for this protocol pair. Available native protocols: " <>
        if(available == "", do: "none", else: available)

    case api_type do
      :anthropic ->
        send_json(conn, 422, %{
          "type" => "error",
          "error" => %{
            "type" => "unsupported_api_surface",
            "code" => "unsupported_protocol_translation",
            "message" => message
          }
        })

      :openai ->
        send_json(conn, 422, %{
          "error" => %{
            "type" => "unsupported_api_surface",
            "code" => "unsupported_protocol_translation",
            "message" => message
          }
        })
    end
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
