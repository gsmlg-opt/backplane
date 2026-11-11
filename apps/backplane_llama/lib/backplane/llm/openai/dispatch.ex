defmodule Backplane.LLM.OpenAI.Dispatch do
  @moduledoc "Native OpenAI HTTP routes, authenticated before any request body is read."
  @behaviour Plug
  import Plug.Conn
  alias Backplane.LLM.{AccessEvent, RateLimiter, UsageAccumulator}
  alias Backplane.LLM.OpenAI.{Request, Service}
  alias Relayixir.Proxy.{HttpPlug, Upstream}

  @paths %{
    "/v1/decisions" => {:decisions, "decisions"},
    "/v1/images/generations" => {:images, "images/generations"},
    "/v1/images/edits" => {:images, "images/edits"},
    "/v1/audio/speech" => {:speech, "audio/speech"},
    "/v1/audio/transcriptions" => {:transcription, "audio/transcriptions"},
    "/v1/realtime/client_secrets" => {:realtime, "realtime/client_secrets"},
    "/v1/realtime/calls" => {:realtime, "realtime/calls"}
  }
  def init(opts), do: opts

  def call(%{method: "POST", request_path: path} = conn, _) when is_map_key(@paths, path) do
    {kind, upstream_path} = Map.fetch!(@paths, path)

    services = Service.list(kind) |> Enum.filter(& &1.enabled)

    case {kind in [:speech, :transcription], services} do
      {true, []} ->
        conn

      {false, []} ->
        error(conn, :model_unavailable) |> halt()

      _ ->
        limit = services |> Enum.map(& &1.max_request_bytes) |> Enum.max()
        dispatch(conn, kind, upstream_path, admission_limit(kind, limit))
    end
  end

  def call(conn, _), do: conn

  defp admission_limit(:speech, limit),
    do: max(limit, Backplane.Audio.Config.policy()["speech_json_bytes"])

  defp admission_limit(:transcription, limit) do
    policy = Backplane.Audio.Config.policy()
    max(limit, policy["upload_bytes"] + policy["multipart_overhead_bytes"])
  end

  defp admission_limit(_, limit), do: limit

  defp dispatch(conn, kind, path, limit) do
    case Request.read(conn, limit) do
      {:ok, conn, request} ->
        with :ok <- request_type(request, path),
             {:ok, model} <- Request.model(request, kind),
             {:ok, route} <- Service.resolve(kind, model) do
          proxy(conn, route, request, path) |> halt()
        else
          {:error, reason}
          when kind in [:speech, :transcription] and reason == :model_unavailable ->
            Backplane.Audio.RouteParser.from_request(conn, kind, request)

          {:error, reason} ->
            error(conn, reason) |> halt()
        end

      {:error, conn, reason} ->
        error(conn, reason) |> halt()
    end
  end

  def proxy(conn, route, request, path) do
    with true <- byte_size(request.body) <= route.service.max_request_bytes,
         {:ok, headers} <- Service.auth_headers(route),
         :ok <- rate_limit(route.provider) do
      body = Request.rewrite(request, route.service.kind, route.raw_model)

      if byte_size(body) <= route.service.max_request_bytes do
        forward(conn, route, body, headers, path)
      else
        error(conn, :request_too_large)
      end
    else
      false -> error(conn, :request_too_large)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp forward(conn, route, body, headers, path) do
    uri = URI.parse(Service.url(route, path))

    access =
      conn
      |> assign(:raw_body, "")
      |> AccessEvent.start(path, :openai)
      |> AccessEvent.put_requested_model(route.requested_model)
      |> AccessEvent.put_resolution(route.provider, route.raw_model, route.api)
      |> AccessEvent.mark_upstream_start()

    acc = UsageAccumulator.new(:openai_json_body)
    access = %{access | request_bytes: byte_size(body), usage_acc: acc}

    upstream = %Upstream{
      scheme: if(uri.scheme == "https", do: :https, else: :http),
      host: uri.host,
      port: uri.port,
      host_forward_mode: :rewrite_to_upstream,
      inject_request_headers: headers,
      request_timeout: route.service.request_timeout_ms,
      first_byte_timeout: route.service.request_timeout_ms,
      max_request_body_size: route.service.max_request_bytes,
      max_response_body_size: route.service.max_response_bytes
    }

    original_path = conn.request_path

    outgoing =
      conn
      |> strip_auth()
      |> Map.put(:request_path, uri.path)
      |> Map.put(:path_info, String.split(uri.path, "/", trim: true))

    result =
      HttpPlug.call(outgoing, upstream,
        body: body,
        on_response_body: fn bytes ->
          UsageAccumulator.scan_chunk(acc, bytes)
          :ok
        end,
        on_response_chunk: fn _bytes -> :ok end
      )

    outcome =
      if result.private[:relayixir_proxy_error] || result.status not in 200..299,
        do: :error,
        else: :success

    AccessEvent.finalize(access, %{result | request_path: original_path}, outcome,
      status: result.status
    )

    result
  end

  defp strip_auth(conn) do
    Enum.reduce(
      ~w(authorization x-api-key api-key x-goog-api-key cookie proxy-authorization chatgpt-account-id x-openai-fedramp),
      conn,
      &delete_req_header(&2, &1)
    )
  end

  defp rate_limit(provider) do
    case RateLimiter.check(provider.id, provider.rpm_limit) do
      :ok -> :ok
      _ -> {:error, :rate_limited}
    end
  end

  defp request_type(%{type: :json, params: %{"session" => session}}, "realtime/client_secrets")
       when is_map(session),
       do: :ok

  defp request_type(%{type: :json}, path)
       when path in [
              "decisions",
              "images/generations",
              "images/edits",
              "audio/speech"
            ],
       do: :ok

  defp request_type(%{type: :multipart}, path)
       when path in ["images/edits", "audio/transcriptions", "realtime/calls"],
       do: :ok

  defp request_type(_, _), do: {:error, :unsupported_media_type}

  def error(conn, reason) do
    status =
      case reason do
        :request_too_large -> 413
        :unsupported_media_type -> 415
        :model_unavailable -> 404
        :credential_unavailable -> 503
        :rate_limited -> 429
        _ -> 400
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-should-retry", "false")
    |> send_resp(
      status,
      Jason.encode!(%{
        error: %{
          type: "invalid_request_error",
          code: to_string(reason),
          message: "OpenAI proxy request failed: #{reason}"
        }
      })
    )
  end
end
