defmodule Backplane.Api.EndpointsLlmTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.{Clients, Endpoints}

  alias Backplane.LLM.{
    ModelAlias,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Settings.Credentials

  defmodule Upstream do
    @moduledoc false
    import Phoenix.ConnTest, only: []
    import Plug.Conn, only: []
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      send_json(conn, %{"id" => "chatcmpl-1", "object" => "chat.completion", "choices" => []})
    end

    post "/v1/messages" do
      send_json(conn, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "content" => [],
        "model" => conn.body_params["model"],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end

    match _, do: send_resp(conn, 404, "")

    defp send_json(conn, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    {:ok, upstream} = Gaoxy.HTTP.start_link(plug: {Upstream, []}, port: 0)
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(upstream, :http)

    {:ok, _} = Credentials.store("ep-llm-key", "sk-ep-llm", "llm")
    {:ok, provider} = Provider.create(%{name: "test", credential: "ep-llm-key"})

    apis =
      for surface <- [:openai, :anthropic] do
        {:ok, api} =
          ProviderApi.create(%{
            provider_id: provider.id,
            api_surface: surface,
            base_url: "http://127.0.0.1:#{port}"
          })

        api
      end

    models =
      for name <- ["model-a", "model-b", "model-c"] do
        {:ok, model} =
          ProviderModel.create(%{provider_id: provider.id, model: name, source: :manual})

        for api <- apis do
          {:ok, _} =
            ProviderModelSurface.create(%{
              provider_model_id: model.id,
              provider_api_id: api.id,
              enabled: true
            })
        end

        model
      end

    {:ok, _} = ModelAlias.create(%{alias: "quick", target: "test/model-a"})
    ModelResolver.clear_cache()
    RateLimiter.reset()

    {:ok, endpoint} =
      Endpoints.create(%{
        name: "openclaw",
        llm_enabled: true,
        models: ["test/model-a", "test/model-b"]
      })

    {:ok, _client, token} =
      Clients.issue_client(%{
        name: "ep-llm-client-#{System.unique_integer([:positive])}",
        scopes: ["*"]
      })

    on_exit(fn ->
      Provider.soft_delete(provider)
      Credentials.delete("ep-llm-key")
      ModelAlias.delete("quick")
      ModelResolver.clear_cache()

      try do
        Gaoxy.stop(upstream)
      catch
        :exit, _ -> :ok
      end
    end)

    %{token: token, endpoint: endpoint, models: models, provider: provider}
  end

  defp call(conn, method, path, token, body \\ nil) do
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    case method do
      :get ->
        get(conn, path)

      :post ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(body))
    end
  end

  defp ids(conn), do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])

  test "lists only allowlisted models", %{conn: conn, token: token} do
    conn = call(conn, :get, "/endpoints/openclaw/v1/models", token)
    assert ids(conn) == ["test/model-a", "test/model-b"]
  end

  test "GET /v1 returns the endpoint resource", %{conn: conn, token: token} do
    body = conn |> call(:get, "/endpoints/openclaw/v1", token) |> json_response(200)
    assert body["resource"] == Backplane.Auth.Resources.uri({:endpoint, "openclaw", :v1})
  end

  test "chat completions allows allowlisted and rejects others", %{conn: conn, token: token} do
    path = "/endpoints/openclaw/v1/chat/completions"
    msgs = [%{"role" => "user", "content" => "hi"}]

    assert conn
           |> call(:post, path, token, %{"model" => "test/model-a", "messages" => msgs})
           |> json_response(200)

    assert %{"error" => %{"code" => "model_not_allowed", "type" => "invalid_request_error"}} =
             build_conn()
             |> call(:post, path, token, %{"model" => "test/model-c", "messages" => msgs})
             |> json_response(403)
  end

  test "messages allows allowlisted and rejects others with permission_error", %{
    conn: conn,
    token: token
  } do
    path = "/endpoints/openclaw/v1/messages"
    body = fn model -> %{"model" => model, "max_tokens" => 1, "messages" => []} end

    assert conn |> call(:post, path, token, body.("test/model-a")) |> json_response(200)

    assert %{"error" => %{"type" => "permission_error"}} =
             build_conn() |> call(:post, path, token, body.("test/model-c")) |> json_response(403)
  end

  test "embeddings rejects models outside the allowlist", %{conn: conn, token: token} do
    assert %{"error" => %{"code" => "model_not_allowed"}} =
             conn
             |> call(:post, "/endpoints/openclaw/v1/embeddings", token, %{
               "model" => "test/model-c",
               "input" => "x"
             })
             |> json_response(403)
  end

  test "an alias that is not allowlisted is rejected", %{conn: conn, token: token} do
    assert %{"error" => %{"code" => "model_not_allowed"}} =
             conn
             |> call(:post, "/endpoints/openclaw/v1/chat/completions", token, %{
               "model" => "quick",
               "messages" => []
             })
             |> json_response(403)
  end

  test "a disabled provider model drops out of the listing but stays stored", %{
    conn: conn,
    token: token,
    models: [_, model_b, _],
    endpoint: endpoint
  } do
    {:ok, _} = ProviderModel.update(model_b, %{enabled: false})
    ModelResolver.clear_cache()

    assert ids(call(conn, :get, "/endpoints/openclaw/v1/models", token)) == ["test/model-a"]

    assert {:ok, %{models: ["test/model-a", "test/model-b"]}} =
             Endpoints.active(endpoint.name, :llm)
  end

  test "unsupported routes and disabled llm return 404", %{conn: conn, token: token, endpoint: ep} do
    for {method, path} <- [
          {:post, "/endpoints/openclaw/v1/audio/speech"},
          {:get, "/endpoints/openclaw/v1/codex/models"},
          {:get, "/endpoints/openclaw/v1/providers/x/models"}
        ] do
      assert %{"error" => %{"type" => "not_found_error"}} =
               build_conn() |> call(method, path, token, %{}) |> json_response(404)
    end

    {:ok, _} = Endpoints.update(ep, %{llm_enabled: false})
    assert conn |> call(:get, "/endpoints/openclaw/v1/models", token) |> response(404)
  end

  test "unrestricted endpoints accept any client; root listing is unaffected", %{
    conn: conn,
    token: token
  } do
    {:ok, _, limited} =
      Clients.issue_client(%{
        name: "ep-limited-#{System.unique_integer([:positive])}",
        scopes: ["llm::*"]
      })

    assert ids(call(conn, :get, "/endpoints/openclaw/v1/models", limited)) ==
             ["test/model-a", "test/model-b"]

    assert build_conn() |> call(:get, "/v1/models", token) |> ids() ==
             ["quick", "test/model-a", "test/model-b", "test/model-c"]
  end
end
