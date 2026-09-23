defmodule Backplane.LLM.Google.RouterComponentTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{ModelAlias, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.Google.Router
  alias Backplane.Settings.Credentials

  @fixture Path.expand(
             "../../../../../../integrations/google-genai/fixtures/official/generate-content-recorded-response.json",
             __DIR__
           )

  defmodule CapturingProxy do
    import Plug.Conn

    @fixture Path.expand(
               "../../../../../../integrations/google-genai/fixtures/official/generate-content-recorded-response.json",
               __DIR__
             )

    def call(conn, upstream, opts) do
      send(self(), {:google_proxy, conn, upstream, opts})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, File.read!(@fixture))
    end
  end

  setup do
    old_proxy = Application.get_env(:backplane_llama, :google_http_proxy)
    old_token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane_llama, :google_http_proxy, CapturingProxy)
    Application.put_env(:backplane, :auth_token, "backplane-client")

    on_exit(fn ->
      restore_env(:backplane_llama, :google_http_proxy, old_proxy)
      restore_env(:backplane, :auth_token, old_token)
    end)

    {:ok, _} = Credentials.store("google-router-key", "google-upstream-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "google-router",
        preset_key: "google-gemini-developer",
        credential: "google-router-key",
        default_headers: %{
          "authorization" => "must-not-win",
          "x-provider-default" => "provider"
        }
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :google,
        base_url: "https://generativelanguage.example.test/v1beta",
        default_headers: %{
          "x-goog-api-key" => "must-not-win",
          "x-api-default" => "api"
        }
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gemini-2.5-pro",
        source: :manual
      })

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id
      })

    {:ok, _} = ModelAlias.put("pro", "google-router/gemini-2.5-pro")
    :ok
  end

  test "forwards raw native request and response with only the bound upstream credential" do
    request_body = ~s({ "contents" : [{"parts":[{"text":"hello"}]}] })

    response =
      :post
      |> conn("/v1beta/models/pro:generateContent", request_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-goog-api-key", "backplane-client")
      |> Router.call(Router.init([]))

    assert response.status == 200
    assert response.resp_body == File.read!(@fixture)

    assert_received {:google_proxy, forwarded, upstream, opts}
    assert forwarded.request_path == "/models/gemini-2.5-pro:generateContent"
    assert get_req_header(forwarded, "authorization") == []
    assert get_req_header(forwarded, "x-goog-api-key") == []
    assert opts[:body] == request_body
    refute Keyword.has_key?(opts, :map_response_body)
    refute Keyword.has_key?(opts, :map_response_chunk)
    assert {"x-goog-api-key", "google-upstream-secret"} in upstream.inject_request_headers
    assert {"authorization", nil} in upstream.inject_request_headers
    assert {"x-provider-default", "provider"} in upstream.inject_request_headers
    assert upstream.default_request_headers == [{"x-api-default", "api"}]
    assert upstream.path_prefix_rewrite == "/v1beta"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
