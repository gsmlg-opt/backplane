defmodule Backplane.LLM.ResponsesLifecycleMapperTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{
    CredentialPlug,
    Provider,
    ProviderApi,
    ResponseRoute,
    ResponsesLifecycleMapper
  }

  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  setup do
    {:ok, _} = Credentials.store("mapper-response-key", "sk-test", "llm")

    {:ok, provider} =
      Provider.create(%{name: "mapper-response", credential: "mapper-response-key"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://example.test/v1",
        native_protocols: [:openai_responses],
        responses_lifecycle: true
      })

    conn =
      conn(:post, "/v1/responses")
      |> assign(:resource_auth, %{kind: :client_token, client_id: "mapper-owner"})

    {:ok, route} = ResponseRoute.admit(conn, provider, api)
    :sys.get_state(Vault)
    on_exit(fn -> :sys.get_state(Vault) end)
    %{route: route, conn: conn, provider: provider, api: api}
  end

  test "recoverable auth uses the pinned DB snapshot even when the Vault cache lags", ctx do
    old_credential = Vault.get(ctx.provider.credential)
    {:ok, _} = Credentials.store(ctx.provider.credential, "sk-new-context", "llm")
    :sys.get_state(Vault)
    :ok = Vault.put(old_credential)
    assert Vault.get(ctx.provider.credential).encrypted_value == old_credential.encrypted_value

    assert {:error, :response_route_changed} = ResponseRoute.credential_snapshot(ctx.route)
    {:ok, route} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    {:ok, credential} = ResponseRoute.credential_snapshot(route)

    assert {:ok, [{"authorization", "Bearer sk-new-context"}]} =
             CredentialPlug.build_responses_auth_headers(ctx.provider, credential)
  end

  test "fragmented CRLF SSE binds before original first-ID bytes are released", ctx do
    {:ok, state} =
      ResponsesLifecycleMapper.init(
        200,
        [{"content-type", "text/event-stream"}],
        {ctx.route, :create}
      )

    first = ": keepalive\r\n\r\nevent: response.created\r\ndata: "

    created =
      Jason.encode!(%{
        type: "response.created",
        sequence_number: 0,
        response: %{id: "resp_fragmented", status: "queued"}
      })

    {:ok, state, chunks} = ResponsesLifecycleMapper.feed(state, first <> created)
    assert IO.iodata_to_binary(chunks) == ""
    assert Repo.get!(ResponseRoute, ctx.route.id).response_id == nil
    {:ok, state, chunks} = ResponsesLifecycleMapper.feed(state, "\r\n\r\n")
    assert IO.iodata_to_binary(chunks) == first <> created <> "\r\n\r\n"
    assert Repo.get!(ResponseRoute, ctx.route.id).response_id == "resp_fragmented"
    {:ok, _, []} = ResponsesLifecycleMapper.finish(state, :eof)
  end

  test "upstream HTTP errors pass through byte for byte without binding", ctx do
    bytes = "{ \"error\": {\"code\": \"cursor_expired\"} }"
    {:ok, state} = ResponsesLifecycleMapper.init(409, [], {ctx.route, :create})
    assert {:ok, ^state, [^bytes]} = ResponsesLifecycleMapper.feed(state, bytes)
    assert ResponsesLifecycleMapper.body(ctx.route, :create, nil, 409, [], bytes) == bytes
    assert Repo.get!(ResponseRoute, ctx.route.id).response_id == nil
  end

  test "ID conflict is diagnostic, preserves upstream request ID and forbids automatic retry",
       ctx do
    assert :ok = ResponseRoute.bind(ctx.route, "resp_conflict", "queued")
    {:ok, another} = ResponseRoute.admit(ctx.conn, ctx.provider, ctx.api)
    bytes = ~s({"id":"resp_conflict","status":"queued"})

    assert {:error, :response_id_conflict, 409, headers, error} =
             ResponsesLifecycleMapper.body(
               another,
               :create,
               nil,
               200,
               [{"content-type", "application/json"}, {"x-request-id", "req_conflict"}],
               bytes
             )

    assert {"x-request-id", "req_conflict"} in headers
    assert {"x-should-retry", "false"} in headers
    refute error =~ "resp_conflict"
    assert {:ok, route, _, _} = ResponseRoute.lookup(ctx.conn, "resp_conflict")
    assert route.id == ctx.route.id
  end

  test "missing ID and truncated pre-ID streams are uncertain, never successful", ctx do
    {:ok, state} =
      ResponsesLifecycleMapper.init(
        200,
        [{"content-type", "text/event-stream"}],
        {ctx.route, :create}
      )

    {:ok, state, _} = ResponsesLifecycleMapper.feed(state, ": ping\n\n")

    assert {:error, :response_outcome_uncertain, _, chunks} =
             ResponsesLifecycleMapper.finish(state, :eof)

    assert IO.iodata_to_binary(chunks) =~ "response_outcome_uncertain"
    assert Repo.get!(ResponseRoute, ctx.route.id).status == "uncertain"
  end

  test "pre-ID upstream SSE errors retain exact bytes without inventing an ID", ctx do
    {:ok, state} =
      ResponsesLifecycleMapper.init(
        200,
        [{"content-type", "text/event-stream"}],
        {ctx.route, :create}
      )

    bytes =
      "event: error\r\ndata: { \"type\":\"error\",\"sequence_number\":0,\"code\":\"upstream_error\",\"message\":\"original error\" }\r\n\r\n"

    {:ok, state, output} = ResponsesLifecycleMapper.feed(state, bytes)
    assert IO.iodata_to_binary(output) == bytes
    assert {:ok, _, []} = ResponsesLifecycleMapper.finish(state, :eof)
    assert Repo.get!(ResponseRoute, ctx.route.id).response_id == nil
  end

  test "queued and in_progress JSON are indexed without terminal-codec translation", ctx do
    bytes = ~s({ "id":"resp_queued", "status":"queued", "output":[] })
    assert ResponsesLifecycleMapper.body(ctx.route, :create, nil, 200, [], bytes) == bytes
    assert {:ok, route, _, _} = ResponseRoute.lookup(ctx.conn, "resp_queued")
    assert route.status == "queued"
    progress = ~s({"id":"resp_queued","status":"in_progress","output":[]})
    assert ResponsesLifecycleMapper.body(route, :retrieve, nil, 200, [], progress) == progress
    assert Repo.get!(ResponseRoute, route.id).status == "in_progress"
  end

  test "pre-ID buffering is bounded and does not expose unindexed bytes", ctx do
    {:ok, state} =
      ResponsesLifecycleMapper.init(
        200,
        [{"content-type", "text/event-stream"}],
        {ctx.route, :create}
      )

    assert {:error, :responses_frame_too_large, _, chunks} =
             ResponsesLifecycleMapper.feed(state, String.duplicate("x", 1_048_577))

    refute IO.iodata_to_binary(chunks) =~ String.duplicate("x", 20)
    assert Repo.get!(ResponseRoute, ctx.route.id).response_id == nil
  end
end
