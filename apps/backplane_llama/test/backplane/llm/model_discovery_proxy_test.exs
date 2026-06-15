defmodule Backplane.LLM.ModelDiscoveryProxyTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{ModelDiscovery, Provider, ProviderApi, ProviderModel}
  alias Backplane.Settings.Credentials

  @proxy_env_keys ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.ProxyEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    previous_req_options = Application.fetch_env(:backplane, :llm_model_discovery_req_options)
    previous_env = snapshot_env(@proxy_env_keys)

    Application.delete_env(:backplane, :llm_model_discovery_req_options)

    on_exit(fn ->
      case previous_req_options do
        {:ok, opts} -> Application.put_env(:backplane, :llm_model_discovery_req_options, opts)
        :error -> Application.delete_env(:backplane, :llm_model_discovery_req_options)
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
    plug(:dispatch)

    get "/models" do
      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-proxy-test"] do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"data" => [%{"id" => "model-via-proxy"}]}))
      else
        send_resp(conn, 401, "missing authorization")
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  test "reload_provider uses HTTP_PROXY for model discovery when target is not bypassed", %{
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

    credential = "proxy-test-key-#{System.unique_integer([:positive])}"
    Credentials.store(credential, "sk-proxy-test", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "proxy-test-provider-#{System.unique_integer([:positive])}",
        credential: credential,
        preset_key: "x-ai"
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:1",
        model_discovery_path: "/models"
      })

    provider = Provider.get(provider.id)

    assert %{discovered: 1, created: 1, updated: 0, errors: []} =
             ModelDiscovery.reload_provider(provider)

    assert [%{model: "model-via-proxy"}] = ProviderModel.list_for_provider(provider.id)
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
