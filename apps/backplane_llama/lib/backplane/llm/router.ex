defmodule Backplane.LLM.Router do
  @moduledoc """
  Plug.Router that handles LLM proxy requests.

  Aggregates LLM providers behind a single OpenAI/Anthropic-compatible endpoint.
  Routes:
  - GET  /v1                           — protected-resource descriptor
  - GET  /v1/models                    — aggregated model listing
  - GET  /v1/codex/models               — explicit Codex model catalog
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
    CodexCatalog,
    ModelExtractor,
    ModelMetadata,
    ModelResolver,
    Provider,
    ProviderApi,
    ProtocolRoute,
    RateLimiter
  }

  alias Backplane.Embedding

  alias Backplane.Audio.{
    AccessLifecycle,
    Binding,
    Config,
    Downstream,
    Error,
    Request,
    Resolver,
    Speech,
    Transcription
  }

  alias Backplane.Audio.Media.Session
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  plug(Backplane.Transport.CORS)
  plug(:match)

  plug(Backplane.Auth.ResourceAuthPlug,
    resource: :v1,
    required_scope: {Backplane.LLM.ResourceAuthorization, :required_scope, []}
  )

  plug(Backplane.LLM.ResourceAuthorization)

  plug(Backplane.Audio.RouteParser)

  plug(:dispatch)

  # ── Routes ────────────────────────────────────────────────────────────────────

  get "/v1" do
    send_json(conn, 200, %{
      "resource" => Backplane.Auth.Resources.uri(:v1),
      "resource_documentation" => Backplane.Auth.Resources.documentation_uri(:v1)
    })
  end

  get "/v1/models" do
    send_json(conn, 200, %{"object" => "list", "data" => build_model_list()})
  end

  get "/v1/codex/models" do
    {catalog, _invalid} = CodexCatalog.response()
    send_json(conn, 200, catalog)
  end

  post "/v1/messages" do
    proxy_request(conn, :anthropic_messages)
  end

  post "/v1/embeddings" do
    proxy_embedding_request(conn)
  end

  post "/v1/audio/speech" do
    audio_contract(conn, :speech)
  end

  post "/v1/audio/transcriptions" do
    audio_contract(conn, :transcription)
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

  defp audio_contract(conn, operation) do
    validator = if operation == :speech, do: &Request.speech/1, else: &Request.transcription/1

    session_result =
      case {conn.private[:audio_session], conn.private[:audio_observer]} do
        {session, observer} when is_pid(session) and is_pid(observer) -> {:ok, session}
        _ -> {:error, Error.new(503, "Audio admission unavailable", nil, "audio_unavailable")}
      end

    case session_result do
      {:ok, session} ->
        try do
          with {:ok, request} <- validator.(conn.body_params),
               request = Map.put(request, :observer, conn.private.audio_observer),
               _ <- AccessLifecycle.update(request.observer, %{requested_model: request.model}),
               {:ok, resolution} <- Resolver.resolve(operation, request.model),
               :ok <- Resolver.validate_request(resolution, request),
               true <- resolution.binding.native_protocol == :minimax do
            deadline = conn.private.audio_deadline
            execute_audio(conn, operation, request, resolution, session, deadline)
          else
            false ->
              audio_error(
                conn,
                Error.new(
                  422,
                  "Unsupported audio provider",
                  "model",
                  "audio_provider_unsupported"
                )
              )

            {:error, %Error{} = error} ->
              audio_error(conn, error)
          end
        rescue
          error ->
            AccessLifecycle.finish(
              conn.private[:audio_observer],
              :error,
              nil,
              "audio_request_failed"
            )

            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            AccessLifecycle.finish(
              conn.private[:audio_observer],
              :error,
              nil,
              "audio_request_failed"
            )

            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          safe_release_audio_session(session)

          case conn.body_params do
            %{"file" => %Plug.Upload{} = upload} -> Plug.Upload.delete(upload)
            _ -> :ok
          end
        end

      {:error, %Error{} = error} ->
        audio_error(conn, error)
    end
  end

  defp execute_audio(conn, :speech, request, resolution, session, deadline) do
    owner = self()

    task =
      owned_audio_task(fn ->
        owner_ref = Process.monitor(owner)

        consumer = fn event, acc ->
          ref = make_ref()
          send(owner, {:audio_event, self(), ref, event})

          receive do
            {:audio_ack, ^ref, :ok} ->
              {:ok, acc}

            {:audio_ack, ^ref, {:error, error}} ->
              {:error, error, acc}

            {:DOWN, ^owner_ref, :process, ^owner, _} ->
              {:error, Error.new(499, "Client disconnected", nil, "audio_cancelled"), acc}
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              {:error, audio_timeout(), acc}
          end
        end

        Speech.run(request, resolution, session, deadline, consumer, nil)
      end)

    consumer = fn
      {:chunk, bytes}, conn -> audio_chunk(conn, bytes, "audio/mpeg")
      {:file, artifact}, conn -> audio_file(conn, artifact)
    end

    case await_audio_task(task, conn, deadline, consumer) do
      {:ok, {:ok, _, _metadata}, conn} ->
        AccessLifecycle.finish(conn.private.audio_observer, :success, 200)
        conn

      {:ok, {:error, %Error{} = error, _, _metadata}, conn} ->
        if conn.state in [:chunked, :file] do
          AccessLifecycle.finish_error(conn.private.audio_observer, error, conn.status)

          raise Plug.Conn.NotSentError,
            message: "Audio stream failed after response commitment: #{error.code}"
        else
          audio_error(conn, error)
        end

      {:error, %Error{} = error, conn} ->
        if conn.state in [:chunked, :file] do
          AccessLifecycle.finish_error(conn.private.audio_observer, error, conn.status)
          raise Plug.Conn.NotSentError, message: "Audio stream interrupted: #{error.code}"
        else
          audio_error(conn, error)
        end
    end
  end

  defp execute_audio(conn, :transcription, request, resolution, session, deadline) do
    task =
      owned_audio_task(fn ->
        Transcription.run(request, resolution, session, deadline)
      end)

    case await_audio_task(task, conn, deadline, fn _, conn -> {:ok, conn} end) do
      {:ok, {:ok, text, _metadata}, conn} ->
        body =
          if request.response_format == "text", do: text, else: Jason.encode!(%{"text" => text})

        mime = if request.response_format == "text", do: "text/plain", else: "application/json"

        sent =
          deliver_audio_response(conn, deadline, byte_size(body), fn ->
            conn |> put_resp_content_type(mime, "utf-8") |> send_resp(200, body)
          end)

        AccessLifecycle.finish(conn.private.audio_observer, :success, 200)
        sent

      {:ok, {:error, %Error{} = error, _metadata}, conn} ->
        audio_error(conn, error)

      {:error, %Error{} = error, conn} ->
        audio_error(conn, error)
    end
  end

  defp deliver_audio_response(conn, deadline, bytes, fun) do
    case Downstream.start(conn, deadline) do
      {:ok, downstream} ->
        try do
          delivered = Downstream.deliver(downstream, deadline, fun)
          AccessLifecycle.delivered(conn.private.audio_observer, bytes)

          case Downstream.restore(delivered, downstream) do
            {:ok, restored} ->
              restored

            {:error, _} ->
              audio_disconnected(conn)
              raise Plug.Conn.NotSentError, message: "Audio client disconnected"
          end
        after
          Downstream.stop(downstream)
        end

      {:error, _} ->
        audio_disconnected(conn)
        raise Plug.Conn.NotSentError, message: "Audio client disconnected"
    end
  end

  defp owned_audio_task(fun) do
    owner = self()
    task = Task.Supervisor.async_nolink(Backplane.Audio.Media.TaskSupervisor, fun)

    spawn(fn ->
      owner_ref = Process.monitor(owner)
      task_ref = Process.monitor(task.pid)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(task.pid, :kill)
        {:DOWN, ^task_ref, :process, _, _} -> :ok
      end
    end)

    task
  end

  defp await_audio_task(task, conn, deadline, consumer) do
    case Downstream.start(conn, deadline) do
      {:ok, downstream} ->
        try do
          result = await_audio_loop(task, conn, deadline, consumer, downstream)
          result_conn = elem(result, tuple_size(result) - 1)

          case Downstream.restore(result_conn, downstream) do
            {:ok, restored} ->
              put_elem(result, tuple_size(result) - 1, restored)

            {:error, error} ->
              AccessLifecycle.finish_error(conn.private.audio_observer, error, result_conn.status)
              raise Plug.Conn.NotSentError, message: error.message
          end
        after
          Downstream.stop(downstream)
          if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        end

      {:error, error} ->
        Task.shutdown(task, :brutal_kill)
        {:error, error, conn}
    end
  end

  defp await_audio_loop(%Task{ref: task_ref} = task, conn, deadline, consumer, downstream) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    raw = if downstream, do: downstream.raw
    http2? = match?(%{kind: :http2}, downstream)

    if timeout == 0 do
      Task.shutdown(task, :brutal_kill)
      {:error, audio_timeout(), conn}
    else
      receive do
        {:bandit, {:rst_stream, _code}} when http2? ->
          Task.shutdown(task, :brutal_kill)
          audio_disconnected(conn)
          raise Bandit.TransportError, message: "Audio client reset stream", error: :closed

        {tag, socket}
        when not is_nil(raw) and socket == raw and tag in [:tcp_closed, :ssl_closed] ->
          Task.shutdown(task, :brutal_kill)
          audio_disconnected(conn)
          raise Plug.Conn.NotSentError, message: "Audio client disconnected"

        {tag, socket, _reason}
        when not is_nil(raw) and socket == raw and tag in [:tcp_error, :ssl_error] ->
          Task.shutdown(task, :brutal_kill)
          audio_disconnected(conn)
          raise Plug.Conn.NotSentError, message: "Audio client disconnected"

        {tag, socket, bytes} when not is_nil(raw) and socket == raw and tag in [:tcp, :ssl] ->
          with {:ok, next_conn} <- Downstream.append(conn, bytes),
               :ok <- Downstream.rearm(downstream) do
            await_audio_loop(task, next_conn, deadline, consumer, downstream)
          else
            _ ->
              Task.shutdown(task, :brutal_kill)

              AccessLifecycle.finish(
                conn.private.audio_observer,
                :error,
                conn.status,
                "audio_pipeline_too_large"
              )

              raise Plug.Conn.NotSentError, message: "Audio pipelined input exceeded limit"
          end

        {:audio_event, pid, ref, event} when pid == task.pid ->
          case Downstream.deliver(downstream, deadline, fn -> consumer.(event, conn) end) do
            {:ok, next_conn} ->
              bytes =
                case event do
                  {:chunk, bytes} -> byte_size(bytes)
                  {:file, artifact} -> artifact.bytes
                end

              AccessLifecycle.delivered(conn.private.audio_observer, bytes)
              send(pid, {:audio_ack, ref, :ok})
              await_audio_loop(task, next_conn, deadline, consumer, downstream)

            {:error, %Error{} = error, next_conn} ->
              send(pid, {:audio_ack, ref, {:error, error}})
              await_audio_loop(task, next_conn, deadline, consumer, downstream)
          end

        {^task_ref, result} ->
          Task.ignore(task)
          {:ok, result, conn}

        {:DOWN, ^task_ref, :process, _pid, _reason} ->
          {:error, Error.new(503, "Audio worker failed", nil, "audio_unavailable"), conn}
      after
        timeout ->
          Task.shutdown(task, :brutal_kill)
          {:error, audio_timeout(), conn}
      end
    end
  end

  defp audio_timeout,
    do: Error.new(504, "Audio request timed out", nil, "audio_timeout", "api_error")

  defp audio_file(conn, %{path: path, mime: mime, plan: %{target: %{extension: extension}}}) do
    if File.regular?(path) do
      conn =
        conn
        |> put_resp_content_type(mime, nil)
        |> put_resp_header("cache-control", "no-transform")
        |> put_resp_header("content-disposition", "attachment; filename=\"speech.#{extension}\"")
        |> send_file(200, path)

      {:ok, conn}
    else
      {:error, Error.new(503, "Audio output unavailable", nil, "audio_output_unavailable"), conn}
    end
  end

  defp audio_chunk(conn, bytes, mime) do
    conn =
      if conn.state == :unset,
        do:
          conn
          |> put_resp_content_type(mime, nil)
          |> put_resp_header("cache-control", "no-transform")
          |> send_chunked(200),
        else: conn

    case chunk(conn, bytes) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, Error.new(499, "Client disconnected", nil, "audio_cancelled"), conn}
    end
  end

  defp safe_release_audio_session(session) do
    Session.release(session)
  catch
    :exit, _ -> :ok
  end

  defp audio_error(conn, error) do
    sent = Error.send(conn, error)
    AccessLifecycle.finish_error(conn.private[:audio_observer], error)
    sent
  end

  defp audio_disconnected(conn) do
    AccessLifecycle.finish(
      conn.private[:audio_observer],
      :cancelled,
      conn.status,
      "audio_cancelled"
    )
  end

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
            {model_string, raw_model},
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
         {requested_model, raw_model},
         rewritten_body,
         client_protocol,
         api_type,
         access
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

    auto_models = AutoModel.list_configurations()
    custom_aliases = ModelAlias.list()
    provider_alias_names = ModelAlias.provider_names()

    resolver_names =
      MapSet.new(Enum.map(auto_models, & &1.name) ++ Enum.map(custom_aliases, & &1.alias))

    provider_entries =
      for provider <- providers,
          provider.name not in provider_alias_names,
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
      for auto_model <- auto_models,
          auto_model.enabled do
        %{
          "id" => auto_model.name,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    custom_alias_entries =
      for model_alias <- custom_aliases do
        %{
          "id" => model_alias.alias,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => "backplane"
        }
      end

    provider_alias_entries =
      for provider <- providers,
          provider.name in provider_alias_names,
          model <- provider.models,
          model.enabled do
        %{
          "id" => model.model,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name,
          "provider" => provider.name,
          "canonical_id" => model.model
        }
      end

    # Build both namespaced and configured provider-alias targets from the
    # preloaded catalog. Later OpenAI targets take precedence over Anthropic.
    available_targets =
      for api_surface <- [:anthropic, :openai],
          provider <- providers,
          api <- provider.apis,
          api.enabled and api.api_surface == api_surface,
          model <- provider.models,
          model.enabled,
          surface <- model.surfaces,
          surface.enabled and surface.provider_api_id == api.id do
        {provider, model, surface, api}
      end

    provider_targets =
      Map.new(available_targets, fn {provider, model, _surface, _api} = target ->
        {"#{provider.name}/#{model.model}", target}
      end)

    provider_alias_targets =
      for api_surface <- [:anthropic, :openai],
          provider_name <- Enum.reverse(provider_alias_names),
          target <- available_targets,
          {provider, model, _surface, api} = target,
          provider.name == provider_name and api.api_surface == api_surface,
          into: %{} do
        {model.model, target}
      end

    entries =
      (provider_entries ++ auto_model_entries ++ custom_alias_entries ++ provider_alias_entries)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])

    resolved_entries =
      for entry <- entries,
          target =
            selected_model_target(
              providers,
              provider_targets,
              provider_alias_targets,
              resolver_names,
              entry["id"]
            ),
          not is_nil(target) do
        {provider, model, surface, _api} = target
        raw_metadata = Map.merge(model.metadata || %{}, surface.metadata || %{})
        metadata = ModelMetadata.normalize(provider.preset_key, raw_metadata)
        Map.put(entry, "metadata", metadata)
      end

    audio_entries =
      if Config.enabled?() do
        enabled_bindings =
          Binding.list()
          |> Enum.filter(fn binding ->
            binding.enabled and binding.provider.enabled and is_nil(binding.provider.deleted_at) and
              binding.provider_model.enabled
          end)

        public_names =
          Enum.map(enabled_bindings, fn binding ->
            "#{binding.provider.name}/#{binding.provider_model.model}"
          end) ++
            Enum.map(custom_aliases, & &1.alias) ++
            for(
              binding <- enabled_bindings,
              binding.provider.name in provider_alias_names,
              do: binding.provider_model.model
            )

        for name <- Enum.uniq(public_names),
            Enum.any?([:speech, :transcription], fn operation ->
              match?({:ok, _}, Resolver.resolve(operation, name))
            end) do
          %{
            "id" => name,
            "object" => "model",
            "created" => 1_700_000_000,
            "owned_by" => "backplane"
          }
        end
      else
        []
      end

    (resolved_entries ++ audio_entries)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp selected_model_target(
         providers,
         provider_targets,
         provider_alias_targets,
         resolver_names,
         id
       )
       when is_binary(id) do
    case String.split(id, "/", parts: 2) do
      [_provider_name, _raw_model] ->
        Map.get(provider_targets, id)

      [_alias_name] ->
        if MapSet.member?(resolver_names, id),
          do: selected_alias_target(providers, id),
          else: Map.get(provider_alias_targets, id)
    end
  end

  defp selected_alias_target(providers, id) do
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
