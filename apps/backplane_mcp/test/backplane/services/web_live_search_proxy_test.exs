defmodule Backplane.Services.WebLiveSearchProxyTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Services.Web
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @proxy_env_keys ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.ProxyEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    previous_req_options = Application.fetch_env(:backplane, :web_live_search_req_options)
    previous_env = snapshot_env(@proxy_env_keys)

    Application.delete_env(:backplane, :web_live_search_req_options)

    Settings.set("services.web.enabled", true)
    Settings.set("services.web_live_search.models", [])
    Settings.set("services.web_live_search.model", nil)
    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      case previous_req_options do
        {:ok, opts} -> Application.put_env(:backplane, :web_live_search_req_options, opts)
        :error -> Application.delete_env(:backplane, :web_live_search_req_options)
      end

      restore_env(previous_env)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{proxy_port: port}
  end

  defmodule ProxyEndpoint do
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    post "/v1/responses" do
      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer live-secret"] do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "id" => "resp_live_proxy",
            "model" => conn.body_params["model"],
            "output_text" => "Live search reached the proxy",
            "usage" => %{}
          })
        )
      else
        send_resp(conn, 401, "missing authorization")
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  test "web::live_search uses HTTP_PROXY when provider target is not bypassed", %{
    proxy_port: proxy_port
  } do
    System.put_env("HTTP_PROXY", "http://localhost:#{proxy_port}")
    System.delete_env("http_proxy")
    System.delete_env("HTTPS_PROXY")
    System.delete_env("https_proxy")
    System.delete_env("ALL_PROXY")
    System.delete_env("all_proxy")
    System.put_env("NO_PROXY", "127.0.0.1")
    System.put_env("no_proxy", "127.0.0.1")

    create_openai_model("xai-live-proxy", "grok-4.3",
      preset_key: "x-ai",
      base_url: "http://localhost:1/v1"
    )

    Settings.set("services.web_live_search.models", ["xai-live-proxy/grok-4.3"])

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => "current search result"
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "current search result"

    assert [
             %{
               "provider" => "xai-live-proxy",
               "model" => "grok-4.3",
               "title" => "Live search answer",
               "url" => "",
               "snippet" => "Live search reached the proxy"
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "xai-live-proxy",
               "model" => "grok-4.3"
             }
           ] = result["usage"]
  end

  defp live_search_tool do
    Enum.find(Web.tools(), &(&1.name == "web::live_search")) ||
      flunk("expected web::live_search to be registered")
  end

  defp create_openai_model(provider_name, model_id, opts) do
    credential_name = "#{provider_name}-cred"
    {:ok, _} = Credentials.store(credential_name, "live-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: provider_name,
        credential: credential_name,
        preset_key: Keyword.get(opts, :preset_key)
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: Keyword.get(opts, :base_url, "https://api.openai.com/v1")
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    provider
  end

  defp snapshot_env(keys) do
    Map.new(keys, fn key -> {key, System.get_env(key)} end)
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
