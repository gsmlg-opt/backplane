defmodule Backplane.Api.ResponsesLifecycleEndpointTest do
  use Backplane.Api.DataCase, async: false

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter,
    ResponseRoute
  }

  alias Backplane.Settings.Credentials

  defmodule Upstream do
    use Plug.Router

    plug(:read_request)
    plug(:match)
    plug(:dispatch)

    post "/v1/responses" do
      capture(conn)
      input = conn.body_params["input"] || "queued"
      id = "resp_" <> input
      state = Agent.get(Backplane.Api.ResponsesLifecycleEndpointTest.Store, & &1)

      cond do
        state.create_mode == :sse_error ->
          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("x-request-id", "req_pre_id_error")
            |> send_chunked(200)

          {:ok, conn} = chunk(conn, pre_id_error())
          conn

        state.create_mode == :rejected ->
          conn
          |> put_resp_header("x-request-id", "req_create_rejected")
          |> put_resp_header("retry-after", "13")
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            ~S({ "error": {"code":"upstream_busy","message":"preserve this body"} })
          )

        state.create_mode == :stream_bind_fault ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
          {:ok, conn} = chunk(conn, initial_events(id))
          conn

        state.create_mode == :uncertain ->
          send(state.test_pid, {:submission_accepted, self()})

          receive do
            :release_submission -> json(conn, 200, %{"id" => id, "status" => "queued"})
          after
            5_000 -> conn
          end

        conn.body_params["stream"] == true ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
          bytes = initial_events(id)
          split = div(byte_size(bytes), 2)
          {:ok, conn} = chunk(conn, binary_part(bytes, 0, split))
          {:ok, conn} = chunk(conn, binary_part(bytes, split, byte_size(bytes) - split))
          send(state.test_pid, {:created_stream_ready, self()})

          receive do
            :release_stream ->
              case chunk(conn, resume_events(id)) do
                {:ok, conn} -> conn
                {:error, :closed} -> conn
              end
          after
            2_000 -> conn
          end

        state.create_mode == :chunked_json ->
          body = Jason.encode!(%{"id" => id, "status" => "queued", "output" => []})
          {first, last} = String.split_at(body, 12)
          conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)
          {:ok, conn} = chunk(conn, first)
          {:ok, conn} = chunk(conn, last)
          conn

        true ->
          json(conn, 200, %{"id" => id, "status" => response_status(input), "output" => []})
      end
    end

    get "/v1/responses/:id" do
      capture(conn)
      conn = fetch_query_params(conn)

      cond do
        conn.query_params["fault"] in ["expired", "missing", "unsupported"] ->
          {status, code} =
            case conn.query_params["fault"] do
              "expired" -> {409, "cursor_expired"}
              "missing" -> {404, "response_not_found"}
              "unsupported" -> {501, "resume_unsupported"}
            end

          conn
          |> put_resp_header("x-request-id", "req_" <> code)
          |> put_resp_header("retry-after", "17")
          |> put_resp_content_type("application/json")
          |> send_resp(
            status,
            Jason.encode!(%{error: %{code: code, detail: "original upstream error"}})
          )

        conn.query_params["stream"] == "true" ->
          after_sequence = String.to_integer(conn.query_params["starting_after"] || "-1")

          bytes =
            all_events(id)
            |> Enum.filter(&(elem(&1, 0) > after_sequence))
            |> Enum.map(&elem(&1, 1))

          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("x-request-id", "req_replay")
            |> send_chunked(200)

          {:ok, conn} = chunk(conn, keepalive())
          {:ok, conn} = chunk(conn, bytes)
          conn

        true ->
          json(conn, 200, %{
            "id" => id,
            "status" => response_status(String.replace_prefix(id, "resp_", "")),
            "output" => []
          })
      end
    end

    post "/v1/responses/:id/cancel" do
      capture(conn)

      if Agent.get(
           Backplane.Api.ResponsesLifecycleEndpointTest.Store,
           &Map.get(&1, :cancel_error, false)
         ) do
        conn
        |> put_resp_header("x-request-id", "req_cancel_rejected")
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          ~S({"error":{"code":"not_background","message":"upstream cancellation rejected"}})
        )
      else
        json(conn, 200, %{
          "id" => id,
          "status" => "cancelled",
          "output" => [],
          "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
        })
      end
    end

    delete "/v1/responses/:id" do
      capture(conn)
      json(conn, 200, %{"id" => id, "object" => "response.deleted", "deleted" => true})
    end

    match(_, do: send_resp(conn, 404, "upstream route not found"))

    def keepalive do
      ": keepalive\r\n\r\n" <>
        "event: keepalive\r\ndata: {\"type\":\"keepalive\",\"sequence_number\":999}\r\n\r\n"
    end

    def pre_id_error,
      do:
        "event: error\r\ndata: { \"type\":\"error\",\"sequence_number\":0,\"code\":\"upstream_stream_error\",\"message\":\"unchanged error\" }\r\n\r\n"

    def initial_events(id),
      do: all_events(id) |> Enum.take(3) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

    def resume_events(id),
      do: all_events(id) |> Enum.drop(3) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

    def all_events(id) do
      [
        {0, %{"type" => "response.created", "response" => %{"id" => id, "status" => "queued"}}},
        {1, %{"type" => "response.queued", "response" => %{"id" => id, "status" => "queued"}}},
        {2, %{"type" => "response.output_text.delta", "delta" => "A"}},
        {3,
         %{
           "type" => "response.in_progress",
           "response" => %{"id" => id, "status" => "in_progress"}
         }},
        {4, %{"type" => "response.output_text.delta", "delta" => "B"}},
        {5, %{"type" => "response.output_text.delta", "delta" => "C"}},
        {6,
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => id,
             "status" => "completed",
             "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
           }
         }}
      ]
      |> Enum.map(fn {sequence, event} ->
        event = Map.put(event, "sequence_number", sequence)
        {sequence, "event: #{event["type"]}\r\ndata: #{Jason.encode!(event)}\r\n\r\n"}
      end)
    end

    defp read_request(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      params = if body == "", do: %{}, else: Jason.decode!(body)
      conn |> assign(:raw_request, body) |> Map.put(:body_params, params)
    end

    defp capture(conn) do
      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        body: conn.body_params,
        raw: conn.assigns.raw_request,
        headers: conn.req_headers
      }

      Agent.update(
        Backplane.Api.ResponsesLifecycleEndpointTest.Store,
        &Map.update!(&1, :requests, fn requests -> requests ++ [request] end)
      )
    end

    defp response_status(value)
         when value in ["queued", "in_progress", "completed", "failed", "cancelled", "incomplete"],
         do: value

    defp response_status(_), do: "queued"

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    {:ok, _client, token} =
      Backplane.Clients.issue_client(%{name: "responses-owner", scopes: ["llm::*"]})

    {:ok, _other_client, other_token} =
      Backplane.Clients.issue_client(%{name: "responses-other", scopes: ["llm::*"]})

    {:ok, _models_client, models_token} =
      Backplane.Clients.issue_client(%{name: "responses-models-only", scopes: ["llm::models"]})

    test_pid = self()

    {:ok, store} =
      Agent.start_link(fn -> %{requests: [], test_pid: test_pid, create_mode: :json} end,
        name: __MODULE__.Store
      )

    {:ok, upstream} = Gaoxy.HTTP.start_link(plug: {Upstream, []}, port: 0)
    %{local: {:ok, {_ip, upstream_port}}} = Gaoxy.info(upstream, :http)
    {:ok, endpoint} = Gaoxy.HTTP.start_link(plug: {Backplane.Api.Endpoint, []}, port: 0)
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(endpoint, :http)
    {:ok, _} = Credentials.store("responses-key", "sk-response-provider", "llm")
    {:ok, provider} = Provider.create(%{name: "responses-provider", credential: "responses-key"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:#{upstream_port}",
        native_protocols: [:openai_responses],
        responses_lifecycle: true
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "responses-model", source: :manual})

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      stop_server(endpoint)
      stop_server(upstream)
      if Process.alive?(store), do: Agent.stop(store)
      ModelResolver.clear_cache()
      RateLimiter.reset()
      Backplane.Settings.Credentials.Vault.remove("responses-key")
      Credentials.invalidate_token("responses-key")
    end)

    %{
      port: port,
      endpoint: endpoint,
      token: token,
      other_token: other_token,
      models_token: models_token,
      api: api,
      provider: provider
    }
  end

  test "default disabled forwarding preserves background, stream, store and extension fields",
       ctx do
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_lifecycle: false})

    body =
      request_body("queued", %{
        "background" => true,
        "stream" => false,
        "store" => false,
        "provider_extension" => %{"keep" => "雪"}
      })

    assert {200, _, _} =
             request(ctx, "POST", "/v1/responses", body, [{"openai-project", "caller-project"}])

    [submission] = requests()
    assert {"openai-project", "caller-project"} in submission.headers
    assert submission.body["background"] == true
    assert submission.body["stream"] == false
    assert submission.body["store"] == false
    assert submission.body["provider_extension"] == %{"keep" => "雪"}
    assert Repo.all(ResponseRoute) == []
    assert {404, _, error} = request(ctx, "GET", "/v1/responses/resp_queued")
    assert error =~ "response_not_found"
    assert length(requests()) == 1
  end

  test "create binds its ID before exposure, with no injected asynchronous flags", ctx do
    assert {200, _, body} = request(ctx, "POST", "/v1/responses", request_body("queued"))
    assert Jason.decode!(body)["id"] == "resp_queued"
    [route] = Repo.all(ResponseRoute)
    assert route.response_id == "resp_queued"
    assert route.provider_id == ctx.provider.id
    assert route.provider_api_id == ctx.api.id
    assert route.status == "queued"
    [submission] = requests()
    refute Map.has_key?(submission.body, "background")
    refute Map.has_key?(submission.body, "stream")
    refute Map.has_key?(submission.body, "store")

    assert submission.headers |> Enum.filter(&(elem(&1, 0) == "authorization")) == [
             {"authorization", "Bearer sk-response-provider"}
           ]
  end

  test "chunked JSON creates retain a durable mapping", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | create_mode: :chunked_json})
    assert {200, _, body} = request(ctx, "POST", "/v1/responses", request_body("chunked"))
    assert Jason.decode!(body)["id"] == "resp_chunked"
    assert [%ResponseRoute{response_id: "resp_chunked"}] = Repo.all(ResponseRoute)
    assert {200, _, _} = request(ctx, "GET", "/v1/responses/resp_chunked")
  end

  test "disconnect resumes the same response with an exclusive durable cursor and client deduplication",
       ctx do
    {:ok, socket} = connect(ctx.port)

    :ok =
      :gen_tcp.send(
        socket,
        http_request(
          ctx.token,
          "POST",
          "/v1/responses",
          request_body("stream", %{"background" => true, "stream" => true, "store" => false})
        )
      )

    initial = receive_stream_until(socket, ~S("delta":"A"), "")
    assert_receive {:created_stream_ready, upstream_pid}, 2_000
    assert [%ResponseRoute{response_id: "resp_stream"}] = Repo.all(ResponseRoute)
    :ok = :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
    send(upstream_pid, :release_stream)

    assert initial == Upstream.initial_events("resp_stream")
    first_state = apply_events(initial, %{cursor: -1, text: "", status: nil, id: nil})
    assert first_state == %{cursor: 2, text: "A", status: "queued", id: "resp_stream"}

    path =
      "/v1/responses/resp_stream?stream=true&starting_after=2&include%5B%5D=message.output_text.logprobs"

    assert {200, headers, replay} = request(ctx, "GET", path)
    assert headers =~ "x-request-id: req_replay"
    assert replay == Upstream.keepalive() <> Upstream.resume_events("resp_stream")
    final = apply_events(replay, first_state)
    assert final == %{cursor: 6, text: "ABC", status: "completed", id: "resp_stream"}
    assert apply_events(replay, final) == final
    assert Enum.count(requests(), &(&1.method == "POST")) == 1

    assert List.last(requests()).query ==
             "stream=true&starting_after=2&include%5B%5D=message.output_text.logprobs"

    assert {200, _, final_replay} =
             request(ctx, "GET", "/v1/responses/resp_stream?stream=true&starting_after=6")

    assert final_replay == Upstream.keepalive()
  end

  test "retrieval preserves queued, in_progress and terminal response objects", ctx do
    for status <- ~w(queued in_progress completed failed cancelled incomplete) do
      assert {200, _, _} =
               request(
                 ctx,
                 "POST",
                 "/v1/responses",
                 request_body(status, %{"background" => true})
               )

      assert {200, _, body} = request(ctx, "GET", "/v1/responses/resp_#{status}")
      assert Jason.decode!(body)["status"] == status
    end
  end

  test "cancel and delete use the original provider without a model", ctx do
    assert {200, _, _} =
             request(
               ctx,
               "POST",
               "/v1/responses",
               request_body("cancel", %{"background" => true})
             )

    assert {200, _, cancelled} = request(ctx, "POST", "/v1/responses/resp_cancel/cancel", "{}")
    assert Jason.decode!(cancelled)["status"] == "cancelled"
    assert {200, _, deleted} = request(ctx, "DELETE", "/v1/responses/resp_cancel")
    assert Jason.decode!(deleted)["deleted"] == true

    assert Enum.map(requests(), &{&1.method, &1.path}) == [
             {"POST", "/v1/responses"},
             {"POST", "/v1/responses/resp_cancel/cancel"},
             {"DELETE", "/v1/responses/resp_cancel"}
           ]
  end

  test "an API base ending in v1 preserves lifecycle paths and the original query", ctx do
    {:ok, _} = ProviderApi.update(ctx.api, %{base_url: ctx.api.base_url <> "/v1"})

    assert {200, _, _} =
             request(
               ctx,
               "POST",
               "/v1/responses",
               request_body("versioned", %{"background" => true})
             )

    query = "include%5B%5D=message.output_text.logprobs&extension=%2B%20"
    assert {200, _, _} = request(ctx, "GET", "/v1/responses/resp_versioned?" <> query)
    assert {200, _, _} = request(ctx, "POST", "/v1/responses/resp_versioned/cancel", "{}")
    assert {200, _, _} = request(ctx, "DELETE", "/v1/responses/resp_versioned")

    assert Enum.map(requests(), &{&1.method, &1.path, &1.query}) == [
             {"POST", "/v1/responses", ""},
             {"GET", "/v1/responses/resp_versioned", query},
             {"POST", "/v1/responses/resp_versioned/cancel", ""},
             {"DELETE", "/v1/responses/resp_versioned", ""}
           ]
  end

  test "upstream errors retain status, response headers, body and raw query", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("expired"))

    for {fault, status, code} <- [
          {"expired", 409, "cursor_expired"},
          {"missing", 404, "response_not_found"},
          {"unsupported", 501, "resume_unsupported"}
        ] do
      query = "stream=true&starting_after=52&fault=#{fault}&x=%2B%20"

      assert {^status, headers, body} =
               request(ctx, "GET", "/v1/responses/resp_expired?" <> query)

      assert headers =~ "x-request-id: req_" <> code
      assert headers =~ "retry-after: 17"
      assert body == Jason.encode!(%{error: %{code: code, detail: "original upstream error"}})
      assert List.last(requests()).query == query
    end

    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  test "rejected creates preserve the upstream error and do not invent an ID", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | create_mode: :rejected})

    assert {429, headers, body} =
             request(
               ctx,
               "POST",
               "/v1/responses",
               request_body("rejected", %{"background" => true})
             )

    assert headers =~ "x-request-id: req_create_rejected"
    assert headers =~ "retry-after: 13"
    assert body == ~S({ "error": {"code":"upstream_busy","message":"preserve this body"} })
    assert [%ResponseRoute{response_id: nil, status: "failed"}] = Repo.all(ResponseRoute)
    assert length(requests()) == 1
  end

  test "cancel preserves an upstream eligibility error", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("synchronous"))
    Agent.update(__MODULE__.Store, &Map.put(&1, :cancel_error, true))

    assert {400, headers, body} =
             request(ctx, "POST", "/v1/responses/resp_synchronous/cancel", "{}")

    assert headers =~ "x-request-id: req_cancel_rejected"

    assert body ==
             ~S({"error":{"code":"not_background","message":"upstream cancellation rejected"}})

    assert [%ResponseRoute{status: "queued"}] = Repo.all(ResponseRoute)
    assert length(requests()) == 2
  end

  test "an upstream SSE error before creation retains its bytes and request ID", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | create_mode: :sse_error})

    assert {200, headers, body} =
             request(
               ctx,
               "POST",
               "/v1/responses",
               request_body("stream_error", %{"background" => true, "stream" => true})
             )

    assert headers =~ "x-request-id: req_pre_id_error"
    assert body == Upstream.pre_id_error()
    assert [%ResponseRoute{response_id: nil, status: "uncertain"}] = Repo.all(ResponseRoute)
    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  test "another principal cannot read, resume, cancel or delete an owned response", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("private"))
    other = %{ctx | token: ctx.other_token}

    for {method, path} <- [
          {"GET", "/v1/responses/resp_private"},
          {"GET", "/v1/responses/resp_private?stream=true&starting_after=0"},
          {"POST", "/v1/responses/resp_private/cancel"},
          {"DELETE", "/v1/responses/resp_private"}
        ] do
      assert {404, _, _} = request(other, method, path)
    end

    assert length(requests()) == 1
  end

  test "all lifecycle methods require invoke scope", ctx do
    restricted = %{ctx | token: ctx.models_token}

    for {method, path} <- [
          {"GET", "/v1/responses/resp_unknown"},
          {"POST", "/v1/responses/resp_unknown/cancel"},
          {"DELETE", "/v1/responses/resp_unknown"}
        ] do
      assert {403, _, body} = request(restricted, method, path)
      assert body =~ "insufficient_scope"
    end

    assert requests() == []
  end

  test "provider target and credential rotation fail closed", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("pinned"))
    {:ok, _} = ProviderApi.update(ctx.api, %{base_url: ctx.api.base_url <> "/changed"})
    assert {409, _, body} = request(ctx, "GET", "/v1/responses/resp_pinned")
    assert body =~ "response_route_changed"
    assert length(requests()) == 1
  end

  test "credential rotation cannot silently route a response into another account", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("rotation"))
    {:ok, _} = Credentials.store("responses-key", "sk-rotated-account", "llm")
    assert {409, _, body} = request(ctx, "GET", "/v1/responses/resp_rotation")
    assert body =~ "response_route_changed"
    assert length(requests()) == 1
  end

  test "disabled capability after creation refuses lifecycle forwarding", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("disabled"))
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_lifecycle: false})
    assert {409, _, body} = request(ctx, "GET", "/v1/responses/resp_disabled")
    assert body =~ "response_route_changed"
    assert length(requests()) == 1
  end

  test "a new listening gateway instance resolves the persisted original route", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("restart"))
    stop_server(ctx.endpoint)
    ModelResolver.clear_cache()
    {:ok, endpoint} = Gaoxy.HTTP.start_link(plug: {Backplane.Api.Endpoint, []}, port: 0)
    on_exit(fn -> stop_server(endpoint) end)
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(endpoint, :http)
    assert {200, _, body} = request(%{ctx | port: port}, "GET", "/v1/responses/resp_restart")
    assert Jason.decode!(body)["id"] == "resp_restart"
    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  test "rate-limited lifecycle retrieval is audited with its provider and never forwarded", ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("limited"))
    {:ok, _} = Provider.update(ctx.provider, %{rpm_limit: 1})
    RateLimiter.reset()
    assert {200, _, _} = request(ctx, "GET", "/v1/responses/resp_limited")
    handler = {__MODULE__, :rate_limit_audit, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :llm, :request],
        &__MODULE__.capture_audit/4,
        {self(), ctx.provider.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {429, headers, body} = request(ctx, "GET", "/v1/responses/resp_limited")
    assert_receive {:lifecycle_audit, _measurements, audit}, 2_000
    assert audit.provider_id == ctx.provider.id
    assert audit.status == 429
    assert audit.stream == false
    assert audit.input_tokens == nil
    assert audit.output_tokens == nil
    assert headers =~ "retry-after: "
    assert body =~ "rate_limited"
    assert length(requests()) == 2
  end

  test "request-local organization and project scope cannot alter a recoverable route", ctx do
    for header <- ["openai-project", "openai-organization"] do
      assert {422, _, body} =
               request(ctx, "POST", "/v1/responses", request_body("scoped"), [
                 {header, "caller-context"}
               ])

      assert body =~ "response_scope_header_unsupported"
    end

    assert requests() == []
    assert Repo.all(ResponseRoute) == []
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("scoped"))

    assert {422, _, body} =
             request(ctx, "GET", "/v1/responses/resp_scoped", "", [
               {"openai-project", "another-project"}
             ])

    assert body =~ "response_scope_header_unsupported"
    assert length(requests()) == 1
  end

  test "operator-configured project scope stays pinned across creation and retrieval", ctx do
    {:ok, _} =
      Provider.update(ctx.provider, %{
        default_headers: %{
          "openai-project" => "verified-project",
          "openai-organization" => "verified-org"
        }
      })

    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("operator_scope"))
    assert {200, _, _} = request(ctx, "GET", "/v1/responses/resp_operator_scope")

    for captured <- requests() do
      assert {"openai-project", "verified-project"} in captured.headers
      assert {"openai-organization", "verified-org"} in captured.headers
    end
  end

  test "replay and cancellation emit access audit events without counting generation usage again",
       ctx do
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("audit_replay"))
    assert {200, _, _} = request(ctx, "POST", "/v1/responses", request_body("audit_cancel"))
    handler = {__MODULE__, :lifecycle_audit, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :llm, :request],
        &__MODULE__.capture_audit/4,
        {self(), ctx.provider.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {200, _, replay} =
             request(ctx, "GET", "/v1/responses/resp_audit_replay?stream=true&starting_after=2")

    assert replay =~ ~S("input_tokens":11)
    assert_receive {:lifecycle_audit, replay_measurements, replay_audit}, 2_000
    assert replay_audit.provider_id == ctx.provider.id
    assert replay_audit.status == 200
    assert replay_audit.stream == true
    assert replay_audit.input_tokens == nil
    assert replay_audit.output_tokens == nil
    refute Map.has_key?(replay_measurements, :input_tokens)
    refute Map.has_key?(replay_measurements, :output_tokens)

    assert {200, _, cancelled} =
             request(ctx, "POST", "/v1/responses/resp_audit_cancel/cancel", "{}")

    assert Jason.decode!(cancelled)["usage"] == %{"input_tokens" => 11, "output_tokens" => 7}
    assert_receive {:lifecycle_audit, cancel_measurements, cancel_audit}, 2_000
    assert cancel_audit.provider_id == ctx.provider.id
    assert cancel_audit.status == 200
    assert cancel_audit.stream == false
    assert cancel_audit.input_tokens == nil
    assert cancel_audit.output_tokens == nil
    refute Map.has_key?(cancel_measurements, :input_tokens)
    refute Map.has_key?(cancel_measurements, :output_tokens)
  end

  def capture_audit(
        _event,
        measurements,
        %{provider_id: provider_id} = metadata,
        {test_pid, provider_id}
      ) do
    send(test_pid, {:lifecycle_audit, measurements, metadata})
  end

  def capture_audit(_event, _measurements, _metadata, _config), do: :ok

  test "database admission failure sends no create request", ctx do
    reject_route_writes("INSERT")
    assert {503, _, body} = request(ctx, "POST", "/v1/responses", request_body("database"))
    assert body =~ "responses_index_unavailable"
    assert requests() == []
  end

  test "mapping failure after upstream acceptance does not expose an unindexed ID", ctx do
    reject_route_writes("UPDATE")
    assert {503, headers, body} = request(ctx, "POST", "/v1/responses", request_body("unindexed"))
    assert headers =~ "x-should-retry: false"
    refute body =~ "resp_unindexed"
    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  test "SSE binding failure never forwards the first unindexed response ID", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | create_mode: :stream_bind_fault})
    reject_route_writes("UPDATE")

    assert {200, _, body} =
             request(
               ctx,
               "POST",
               "/v1/responses",
               request_body("sse_unindexed", %{"background" => true, "stream" => true})
             )

    assert body =~ "event: error"
    assert body =~ "responses_index_unavailable"
    refute body =~ "resp_sse_unindexed"
    refute body =~ "response.created"
    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  test "a submission accepted before transport loss is uncertain and is never replayed", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | create_mode: :uncertain})

    submission =
      Task.async(fn ->
        request(ctx, "POST", "/v1/responses", request_body("uncertain", %{"background" => true}))
      end)

    assert_receive {:submission_accepted, upstream_pid}, 2_000
    # Uncertainty is durable even while no transport finalizer has run.
    assert [%ResponseRoute{response_id: nil, status: "uncertain"}] = Repo.all(ResponseRoute)
    Process.exit(upstream_pid, :kill)
    assert {502, headers, body} = Task.await(submission, 5_000)
    assert body =~ "response_outcome_uncertain"
    assert headers =~ "x-should-retry: false"
    assert headers =~ "x-backplane-response-attempt: "
    assert [%ResponseRoute{response_id: nil, status: "uncertain"}] = Repo.all(ResponseRoute)
    assert Enum.count(requests(), &(&1.method == "POST")) == 1
  end

  defp reject_route_writes(operation) do
    condition = if operation == "INSERT", do: "false", else: "response_id IS NULL"

    Repo.query!(
      "ALTER TABLE llm_response_routes ADD CONSTRAINT simulated_response_index_outage CHECK (#{condition}) NOT VALID"
    )
  end

  defp apply_events(bytes, state) do
    bytes
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.reduce(state, fn frame, state ->
      case Enum.find(String.split(frame, ~r/\r?\n/), &String.starts_with?(&1, "data: ")) do
        nil ->
          state

        "data: " <> data ->
          event = Jason.decode!(data)
          sequence = event["sequence_number"]

          if String.starts_with?(event["type"], "response.") and
               is_integer(sequence) and sequence > state.cursor do
            %{
              state
              | cursor: sequence,
                text: state.text <> (event["delta"] || ""),
                status: get_in(event, ["response", "status"]) || state.status,
                id: get_in(event, ["response", "id"]) || state.id
            }
          else
            state
          end
      end
    end)
  end

  defp request_body(input, extra \\ %{}) do
    Jason.encode!(
      Map.merge(%{"model" => "responses-provider/responses-model", "input" => input}, extra)
    )
  end

  defp requests, do: Agent.get(__MODULE__.Store, & &1.requests)

  defp request(ctx, method, path, body \\ "", headers \\ []) do
    {:ok, socket} = connect(ctx.port)

    try do
      :ok = :gen_tcp.send(socket, http_request(ctx.token, method, path, body, headers))
      response = receive_all(socket, "")
      [headers, wire_body] = :binary.split(response, "\r\n\r\n")
      [_, status | _] = headers |> String.split("\r\n") |> hd() |> String.split(" ")

      body =
        if String.contains?(String.downcase(headers), "transfer-encoding: chunked"),
          do: decode_chunked(wire_body, []),
          else: wire_body

      {String.to_integer(status), String.downcase(headers), body}
    after
      :gen_tcp.close(socket)
    end
  end

  defp connect(port),
    do: :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

  defp http_request(token, method, path, body, headers \\ []) do
    [
      method,
      " ",
      path,
      " HTTP/1.1\r\nhost: 127.0.0.1\r\nx-api-key: ",
      token,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "content-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> receive_all(socket, acc <> bytes)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("socket receive failed: #{inspect(reason)}")
    end
  end

  defp receive_stream_until(socket, needle, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> bytes

    case :binary.split(acc, "\r\n\r\n") do
      [_headers, body] ->
        events = decode_partial_chunks(body, [])

        # Existing model normalization emits SSE lines as separate HTTP chunks.
        # Seeing the data payload does not prove its blank-line delimiter arrived.
        if String.contains?(events, needle) and String.ends_with?(events, "\r\n\r\n"),
          do: events,
          else: receive_stream_until(socket, needle, acc)

      _ ->
        receive_stream_until(socket, needle, acc)
    end
  end

  defp decode_partial_chunks(bytes, acc) do
    case :binary.split(bytes, "\r\n") do
      [size_line, rest] ->
        size = size_line |> :binary.split(";") |> hd() |> String.to_integer(16)

        if size > 0 and byte_size(rest) >= size + 2 do
          <<chunk::binary-size(size), "\r\n", remaining::binary>> = rest
          decode_partial_chunks(remaining, [chunk | acc])
        else
          acc |> Enum.reverse() |> IO.iodata_to_binary()
        end

      _ ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp decode_chunked(bytes, acc) do
    [size_line, rest] = :binary.split(bytes, "\r\n")
    size = size_line |> :binary.split(";") |> hd() |> String.to_integer(16)

    if size == 0 do
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    else
      <<chunk::binary-size(size), "\r\n", remaining::binary>> = rest
      decode_chunked(remaining, [chunk | acc])
    end
  end

  defp stop_server(pid) do
    Gaoxy.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
