defmodule Backplane.LLM.EmbeddingsDefaultModelRegressionTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.{Clients, Embedding, Endpoints}
  alias Backplane.LLM.{Provider, ProviderApi, ProxyPlug}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("f6-embed-key", "embed-upstream-secret", "llm")

    {:ok, client, token} =
      Clients.issue_client(%{
        name: "f6-embed-client",
        scopes: ["llm::invoke"],
        active: true
      })

    %{client: client, token: token}
  end

  test "omitted model uses single eligible native default and sends resolved model upstream", %{
    token: token
  } do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/embeddings", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        send(parent, {:embed_body, Formata.JSON.decode!(body)})

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"object":"list","data":[{"index":0,"embedding":[0.1,0.2]}]}))
      end)

    create_embedding_service("f6-oai", server.port, default_model: "text-embedding-3-small")

    resp =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "hello world"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert resp.status == 200
    assert_received {:embed_body, %{"model" => "text-embedding-3-small", "input" => "hello world"}}
  end

  test "rejects malformed models and bodies without substituting default, and rejects no/multiple/disabled defaults",
       %{token: token} do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, :unexpected_upstream_hit)
        upstream |> send_resp(200, ~s({"data":[]}))
      end)

    # 1. No default configured -> 400
    {p1, s1} = create_embedding_service("f6-nodef", server.port, default_model: nil)

    no_def =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert no_def.status == 400
    refute_received :unexpected_upstream_hit

    # 2. Configure default, then test explicit null, empty, non-string, and malformed JSON -> 400
    {:ok, _} = Service.update(s1, %{default_model: "text-embedding-3-small"})

    for bad_body <- [
          ~s({"model":null,"input":"hi"}),
          ~s({"model":"","input":"hi"}),
          ~s({"model":123,"input":"hi"}),
          ~s({not valid json),
          ~s(["array-not-object"])
        ] do
      bad =
        conn(:post, "/v1/embeddings", bad_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> ProxyPlug.call(ProxyPlug.init([]))

      assert bad.status == 400
      refute_received :unexpected_upstream_hit
    end

    # 3. Multiple eligible defaults -> 400 ambiguous_model
    {_p2, s2} = create_embedding_service("f6-def2", server.port, default_model: "text-embedding-3-large")

    ambiguous =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert ambiguous.status == 400
    assert Formata.JSON.decode!(ambiguous.resp_body)["error"]["code"] == "ambiguous_model"
    refute_received :unexpected_upstream_hit

    # 4. Disable both providers -> 400, zero upstream hits
    {:ok, _} = Provider.update(p1, %{enabled: false})
    {:ok, _} = Service.delete(s2)

    disabled =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert disabled.status == 400
    refute_received :unexpected_upstream_hit
  end

  test "enforces named-endpoint model authorization on resolved default model before dispatch", %{
    token: token
  } do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/embeddings", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        send(parent, {:embed_ep_body, Formata.JSON.decode!(body)})

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"object":"list","data":[]}))
      end)

    create_embedding_service("f6-ep-oai", server.port, default_model: "text-embedding-3-small")

    {:ok, denied_ep} =
      Endpoints.create(%{
        name: "f6-deny-ep",
        enabled: true,
        llm_enabled: true,
        models: ["other-model"]
      })

    {:ok, allowed_ep} =
      Endpoints.create(%{
        name: "f6-allow-ep",
        enabled: true,
        llm_enabled: true,
        models: ["text-embedding-3-small"]
      })

    denied =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "blocked"}))
      |> put_private(:backplane_endpoint, denied_ep)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert denied.status == 403
    assert Formata.JSON.decode!(denied.resp_body)["error"]["code"] == "model_not_allowed"
    refute_received {:embed_ep_body, _}

    allowed =
      conn(:post, "/v1/embeddings", Formata.JSON.encode!(%{input: "permitted"}))
      |> put_private(:backplane_endpoint, allowed_ep)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert allowed.status == 200
    assert_received {:embed_ep_body, %{"model" => "text-embedding-3-small", "input" => "permitted"}}
  end

  test "preserves explicit native and legacy embedding routes alongside configured default", %{
    token: token
  } do
    parent = self()

    native_server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/embeddings", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        send(parent, {:native_hit, Formata.JSON.decode!(body)["model"]})
        upstream |> put_resp_content_type("application/json") |> send_resp(200, ~s({"data":[]}))
      end)

    legacy_server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/embeddings", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        send(parent, {:legacy_hit, Formata.JSON.decode!(body)["model"]})
        upstream |> put_resp_content_type("application/json") |> send_resp(200, ~s({"data":[]}))
      end)

    create_embedding_service("f6-native", native_server.port, default_model: "text-embedding-3-small")

    {:ok, %{provider: legacy_p, model: legacy_m}} =
      Embedding.create_provider_with_model(%{
        "name" => "f6-legacy",
        "credential" => "f6-embed-key",
        "base_url" => "http://localhost:#{legacy_server.port}",
        "enabled" => true,
        "model" => "bge-m3",
        "model_enabled" => true
      })

    explicit_native =
      conn(
        :post,
        "/v1/embeddings",
        Formata.JSON.encode!(%{model: "f6-native/text-embedding-3-large", input: "hi"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert explicit_native.status == 200
    assert_received {:native_hit, "text-embedding-3-large"}

    explicit_legacy =
      conn(
        :post,
        "/v1/embeddings",
        Formata.JSON.encode!(%{
          model: Embedding.model_id(%{legacy_m | provider: legacy_p}),
          input: "hi"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert explicit_legacy.status == 200
    assert_received {:legacy_hit, "bge-m3"}
  end

  defp create_embedding_service(name, port, opts) do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        api_type: :openai,
        api_url: "http://localhost:#{port}",
        credential: "f6-embed-key",
        models: []
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{port}"
      })

    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: :embeddings,
        enabled: true,
        model_policy: :passthrough,
        default_model: Keyword.get(opts, :default_model)
      })

    {provider, service}
  end
end
