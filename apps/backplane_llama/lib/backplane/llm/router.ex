defmodule Backplane.LLM.Router do
  @moduledoc """
  Plug.Router that handles LLM proxy requests.

  Aggregates LLM providers behind a single OpenAI/Anthropic-compatible endpoint.
  Routes:
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
    AutoModel,
    CredentialPlug,
    ModelAlias,
    ModelExtractor,
    ModelResolver,
    MoonshotCompat,
    OpenAICodexCompat,
    Provider,
    ProviderApi,
    RateLimiter,
    UsageAccumulator
  }

  alias Backplane.Embedding
  alias Backplane.Transport.CacheBodyReader
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  plug(Backplane.Transport.CORS)
  plug(:match)
  plug(Backplane.Transport.AuthPlug)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 50_000_000,
    body_reader: {CacheBodyReader, :read_body, []}
  )

  plug(:dispatch)

  # ── Routes ────────────────────────────────────────────────────────────────────

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
    raw_body = conn.assigns[:raw_body] || ""

    case ModelExtractor.extract(raw_body) do
      {:error, reason} ->
        send_model_error(conn, api_type, reason)

      {:ok, model_string} ->
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
              api_type
            )
          else
            conn = upstream_request_conn(conn, api_type, provider_api, codex_backend?)
            upstream = build_upstream(provider_api, auth_headers)
            do_proxy(conn, upstream, provider, raw_model, rewritten_body, api_type)
          end
        else
          {:error, :no_provider} ->
            send_not_found(conn, api_type, model_string)

          {:error, :api_type_mismatch, provider} ->
            send_api_type_mismatch(conn, api_type, model_string, provider)

          {:error, retry_after} when is_integer(retry_after) ->
            send_rate_limit_error(conn, api_type, retry_after)

          {:error, :invalid_json} ->
            send_model_error(conn, api_type, :invalid_json)

          {:error, _} ->
            send_error(conn, api_type, 503, "Provider credential not configured")
        end
    end
  end

  defp proxy_embedding_request(conn) do
    raw_body = conn.assigns[:raw_body] || ""

    case ModelExtractor.extract(raw_body) do
      {:error, reason} ->
        send_model_error(conn, :openai, reason)

      {:ok, model_string} ->
        with {:ok, provider, raw_model} <- Embedding.resolve_model(model_string),
             {:ok, rewritten_body} <- ModelExtractor.replace_model(raw_body, raw_model),
             {:ok, auth_headers} <- Embedding.build_auth_headers(provider) do
          upstream = build_embedding_upstream(provider, auth_headers)
          do_embedding_proxy(conn, upstream, rewritten_body)
        else
          {:error, :no_provider} ->
            send_not_found(conn, :openai, model_string)

          {:error, :invalid_json} ->
            send_model_error(conn, :openai, :invalid_json)

          {:error, _} ->
            send_error(conn, :openai, 503, "Provider credential not configured")
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
         api_type
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
        do_proxy(conn, upstream, provider, raw_model, responses_body, api_type, extra_opts)
      after
        cleanup_mapper.()
      end
    else
      {:error, reason} -> send_model_error(conn, api_type, reason)
    end
  end

  defp do_proxy(conn, upstream, provider, raw_model, rewritten_body, api_type, extra_opts \\ []) do
    stream? = is_stream_request?(rewritten_body)
    usage_acc = if stream?, do: UsageAccumulator.new(), else: nil
    start_ms = System.monotonic_time(:millisecond)

    on_chunk =
      if stream? do
        fn chunk -> UsageAccumulator.scan_chunk(usage_acc, chunk) end
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

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    {input_tokens, output_tokens} =
      if stream? do
        UsageAccumulator.get_tokens(usage_acc)
      else
        extract_tokens_from_resp(result_conn, api_type)
      end

    emit_telemetry(provider, raw_model, result_conn, %{
      status: result_conn.status,
      stream?: stream?,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      error_reason: nil,
      latency_ms: latency_ms
    })

    result_conn
  end

  defp do_embedding_proxy(conn, upstream, rewritten_body) do
    conn =
      conn
      |> delete_req_header("authorization")
      |> delete_req_header("x-api-key")

    HttpPlug.call(conn, upstream, body: rewritten_body)
  end

  defp extract_tokens_from_resp(conn, :anthropic) do
    body = conn.resp_body

    with true <- is_binary(body),
         {:ok, %{"usage" => usage}} <- Jason.decode(body),
         input when is_integer(input) <- Map.get(usage, "input_tokens"),
         output when is_integer(output) <- Map.get(usage, "output_tokens") do
      {input, output}
    else
      _ -> {nil, nil}
    end
  end

  defp extract_tokens_from_resp(conn, :openai) do
    body = conn.resp_body

    with true <- is_binary(body),
         {:ok, %{"usage" => usage}} <- Jason.decode(body),
         input when is_integer(input) <- Map.get(usage, "prompt_tokens"),
         output when is_integer(output) <- Map.get(usage, "completion_tokens") do
      {input, output}
    else
      _ -> {nil, nil}
    end
  end

  # ── Telemetry helpers ─────────────────────────────────────────────────────────

  defp emit_telemetry(provider, raw_model, conn, %{
         status: status,
         stream?: stream?,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         error_reason: error_reason,
         latency_ms: latency_ms
       }) do
    :telemetry.execute(
      [:backplane, :llm, :request],
      %{latency_ms: latency_ms, system_time: System.system_time()},
      %{
        provider_id: provider.id,
        model: raw_model,
        status: status,
        stream: stream?,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        client_ip: client_ip(conn),
        error_reason: error_reason
      }
    )
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp is_stream_request?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => true}} -> true
      _ -> false
    end
  end

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
