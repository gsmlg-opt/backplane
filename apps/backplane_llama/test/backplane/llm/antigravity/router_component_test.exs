defmodule Backplane.LLM.Antigravity.RouterComponentTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{ModelAlias, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.Antigravity.Router
  alias Backplane.Settings.Credentials

  defmodule CapturingProxy do
    import Plug.Conn

    def call(conn, upstream, opts) do
      body =
        if conn.query_string == "alt=sse" do
          "data: " <>
            Jason.encode!(%{
              "response" => %{
                "candidates" => [%{"finishReason" => "STOP"}],
                "usageMetadata" => %{"promptTokenCount" => 3, "candidatesTokenCount" => 2}
              }
            }) <> "\n\n"
        else
          Jason.encode!(%{"ok" => true})
        end

      {status, body, private} = Process.get(:antigravity_reply, {200, body, %{}})

      callback =
        if conn.query_string == "alt=sse",
          do: opts[:on_response_chunk],
          else: opts[:on_response_body]

      if callback, do: callback.(body)
      conn = %{conn | private: Map.merge(conn.private, private)}
      send(self(), {:antigravity_proxy, conn, upstream, opts})
      conn |> put_resp_header("retry-after", "7") |> send_resp(status, body)
    end
  end

  setup do
    old_proxy = Application.get_env(:backplane_llama, :antigravity_http_proxy)
    old_token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane_llama, :antigravity_http_proxy, CapturingProxy)
    Application.put_env(:backplane, :auth_token, "backplane-client")

    on_exit(fn ->
      restore_env(:backplane_llama, :antigravity_http_proxy, old_proxy)
      restore_env(:backplane, :auth_token, old_token)
    end)

    {:ok, _} =
      Credentials.store_device_token("antigravity-router-oauth", "google_oauth", %{
        "access_token" => "oauth-upstream-secret",
        "refresh_token" => "refresh-token",
        "expires_at" => System.system_time(:millisecond) + 3_600_000
      })

    {:ok, provider} =
      Provider.create(%{
        name: "antigravity-router",
        preset_key: "google-antigravity",
        credential: "antigravity-router-oauth"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :antigravity,
        base_url: "https://cloudcode.example.test",
        backend_config: %{
          "project_id" => "managed-project",
          "user_agent" => "BackplaneTest/1.0",
          "client_version" => "1.0"
        }
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "gemini-3-pro", source: :manual})

    {:ok, surface} =
      ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})

    %{surface: surface, provider: provider, api: api, model: model}
  end

  test "proxies all five RPCs with trusted OAuth and native bindings" do
    for {rpc, body} <- [
          {"loadCodeAssist", %{}},
          {"onboardUser", %{"tierId" => "free-tier"}},
          {"fetchAvailableModels", %{}},
          {"generateContent", generation_body()},
          {"streamGenerateContent", generation_body()}
        ] do
      assert call_rpc(rpc, body).status == 200
      assert_received {:antigravity_proxy, forwarded, upstream, opts}
      assert forwarded.request_path == "/v1internal:#{rpc}"
      assert forwarded.query_string == if(rpc == "streamGenerateContent", do: "alt=sse", else: "")
      assert get_req_header(forwarded, "authorization") == []
      assert {"authorization", "Bearer oauth-upstream-secret"} in upstream.inject_request_headers
      assert {"user-agent", "BackplaneTest/1.0"} in upstream.inject_request_headers

      forwarded_body = Jason.decode!(opts[:body])

      if rpc in ["generateContent", "streamGenerateContent"] do
        assert forwarded_body["project"] == "managed-project"
        assert forwarded_body["model"] == "gemini-3-pro"
        assert forwarded_body["request"]["opaque"] == %{"signature" => "keep-me"}
        assert is_binary(forwarded_body["request"]["sessionId"])
        assert String.starts_with?(forwarded_body["requestId"], "agent-")
      end
    end
  end

  test "rejects project and query overrides before forwarding" do
    for {rpc, body} <- [
          {"loadCodeAssist", %{"metadata" => %{"duetProject" => "client-project"}}},
          {"fetchAvailableModels", %{"project" => "client-project"}},
          {"generateContent", Map.put(generation_body(), "project", "client-project")}
        ] do
      assert call_rpc(rpc, body).status == 400
      refute_received {:antigravity_proxy, _, _, _}
    end

    assert call_rpc("fetchAvailableModels", %{}, "debug=true").status == 400
    refute_received {:antigravity_proxy, _, _, _}

    assert call_rpc("streamGenerateContent", generation_body(), "alt=sse").status == 200
    assert_received {:antigravity_proxy, _, _, _}
  end

  test "revalidates a disabled model surface immediately", %{surface: surface} do
    {:ok, _surface} = ProviderModelSurface.update(surface, %{enabled: false})
    assert call_rpc("generateContent", generation_body()).status == 404
    refute_received {:antigravity_proxy, _, _, _}
  end

  test "resolves aliases within the named provider and rewrites only the outer model" do
    {:ok, _} = ModelAlias.put("ag-test-alias", "antigravity-router/gemini-3-pro")
    body = Map.put(generation_body(), "model", "ag-test-alias")
    assert call_rpc("generateContent", body).status == 200
    assert_received {:antigravity_proxy, _, _, opts}
    forwarded = Jason.decode!(opts[:body])
    assert forwarded["model"] == "gemini-3-pro"
    assert Map.delete(forwarded["request"], "sessionId") == body["request"]

    {:ok, _} = ModelAlias.put("ag-foreign-alias", "another-provider/gemini-3-pro")
    assert call_rpc("generateContent", Map.put(body, "model", "ag-foreign-alias")).status == 404
    refute_received {:antigravity_proxy, _, _, _}
  end

  test "malformed inner request cannot crash generation or control operations" do
    for request <- ["invalid", [], 3, nil] do
      assert call_rpc("generateContent", Map.put(generation_body(), "request", request)).status ==
               400

      refute_received {:antigravity_proxy, _, _, _}
      assert call_rpc("loadCodeAssist", %{"request" => request}).status == 200
      assert_received {:antigravity_proxy, _, _, _}
    end
  end

  test "upstream status headers and raw native bodies survive without conversion" do
    for status <- [200, 400, 401, 403, 429, 500, 503] do
      raw = ~s({ "response" : {"unknown":true}, "native_error": "untouched" })
      Process.put(:antigravity_reply, {status, raw, %{}})
      result = call_rpc("generateContent", generation_body())
      assert result.status == status
      assert result.resp_body == raw
      assert get_resp_header(result, "retry-after") == ["7"]
      assert_received {:antigravity_proxy, _, _, opts}
      refute Keyword.has_key?(opts, :map_response_body)
      refute Keyword.has_key?(opts, :map_response_chunk)
    end
  end

  test "SSE bytes survive malformed observation and transport failures" do
    raw = "data: {broken}\n\ndata: {\"response\":{\"opaque\":true}}\n\n"

    for private <- [
          %{},
          %{relayixir_proxy_error: :timeout},
          %{relayixir_downstream_disconnected: true}
        ] do
      Process.put(:antigravity_reply, {200, raw, private})
      result = call_rpc("streamGenerateContent", generation_body())
      assert result.resp_body == raw
      assert_received {:antigravity_proxy, _, _, opts}
      refute Keyword.has_key?(opts, :map_response_chunk)
    end
  end

  test "provider and API revocations take effect immediately", %{provider: provider, api: api} do
    {:ok, _} = Provider.update(provider, %{enabled: false})
    assert call_rpc("generateContent", generation_body()).status == 404
    {:ok, _} = Provider.update(Provider.get(provider.id), %{enabled: true})
    {:ok, _} = ProviderApi.update(api, %{enabled: false})
    assert call_rpc("generateContent", generation_body()).status == 404
    refute_received {:antigravity_proxy, _, _, _}
  end

  test "trusted headers win and incoming routing headers cannot escape", %{
    provider: provider,
    api: api
  } do
    {:ok, _} =
      Provider.update(provider, %{
        default_headers: %{
          "Authorization" => "spoof",
          "x-goog-user-project" => "spoof",
          "x-client-version" => "spoof"
        }
      })

    {:ok, _} =
      ProviderApi.update(api, %{
        default_headers: %{"authorization" => "spoof", "x-machine-session-id" => "spoof"}
      })

    result =
      :post
      |> conn(
        "/antigravity/providers/antigravity-router/v1internal:generateContent",
        Jason.encode!(generation_body())
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer backplane-client")
      |> put_req_header("x-goog-user-project", "caller-project")
      |> put_req_header("cookie", "private-cookie")
      |> put_req_header("x-machine-session-id", "caller-header")
      |> Router.call([])

    assert result.status == 200
    assert_received {:antigravity_proxy, forwarded, upstream, opts}
    assert get_req_header(forwarded, "cookie") == []
    assert get_req_header(forwarded, "x-goog-user-project") == []
    refute inspect(upstream.inject_request_headers) =~ "spoof"
    refute inspect(upstream.default_request_headers) =~ "spoof"
    body = Jason.decode!(opts[:body])

    assert {"x-machine-session-id", body["request"]["sessionId"]} in upstream.inject_request_headers
  end

  test "missing project and wrong credential type fail before upstream", %{
    api: api,
    provider: provider
  } do
    {:ok, api} = ProviderApi.update(api, %{backend_config: %{}})
    assert call_rpc("generateContent", generation_body()).status == 400
    {:ok, _} = ProviderApi.update(api, %{backend_config: %{"project_id" => "managed-project"}})
    {:ok, _} = Credentials.store("ag-wrong-key", "api-key", "llm")
    assert {:error, _} = Provider.update(provider, %{credential: "ag-wrong-key"})
    provider |> Ecto.Changeset.change(credential: "ag-wrong-key") |> Repo.update!()
    assert call_rpc("generateContent", generation_body()).status == 503
    refute_received {:antigravity_proxy, _, _, _}
  end

  test "actual database client authentication cannot use invoke scope for enrollment" do
    {:ok, _} =
      Backplane.Clients.create_client(%{
        name: "AG scoped client",
        token: "ag-invoke-token",
        scopes: ["llm::invoke"],
        active: true
      })

    result =
      :post
      |> conn(
        "/antigravity/providers/antigravity-router/v1internal:onboardUser",
        ~s({"tierId":"free-tier"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer ag-invoke-token")
      |> Router.call([])

    assert result.status == 403
    refute_received {:antigravity_proxy, _, _, _}
  end

  test "built-in model aliases use Antigravity routes and observe immediate revocation", %{
    surface: surface
  } do
    {:ok, _} =
      Backplane.LLM.AutoModel.configure_targets("fast", ["antigravity-router/gemini-3-pro"])

    body = Map.put(generation_body(), "model", "fast")
    assert call_rpc("generateContent", body).status == 200
    assert_received {:antigravity_proxy, _, _, opts}
    assert Jason.decode!(opts[:body])["model"] == "gemini-3-pro"
    {:ok, _} = ProviderModelSurface.update(surface, %{enabled: false})
    assert call_rpc("generateContent", body).status == 404
    refute_received {:antigravity_proxy, _, _, _}
  end

  defp call_rpc(rpc, body, query \\ "") do
    path = "/antigravity/providers/antigravity-router/v1internal:#{rpc}"
    path = if query == "", do: path, else: path <> "?" <> query

    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer backplane-client")
    |> Router.call(Router.init([]))
  end

  defp generation_body do
    %{
      "model" => "gemini-3-pro",
      "request" => %{
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "hello"}]}],
        "opaque" => %{"signature" => "keep-me"}
      }
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
