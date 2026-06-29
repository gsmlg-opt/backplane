defmodule Backplane.Monitor.Providers.ClaudeCodeTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.ClaudeCode

  defmodule UsageProxyEndpoint do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/oauth/usage" do
      headers = Map.new(conn.req_headers)

      if headers["authorization"] == "Bearer sk-ant-oat01-usage" and
           headers["anthropic-beta"] == "oauth-2025-04-20" do
        body = %{
          "five_hour" => %{"utilization" => 2.0},
          "seven_day" => %{"utilization" => 1.0}
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))
      else
        send_resp(conn, 401, "missing auth headers")
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  test "fetch_oauth/2 uses HTTP_PROXY for usage requests when target is not in NO_PROXY" do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.UsageProxyEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    previous_opts = Application.get_env(:backplane, :claude_code_monitor_req_options)

    previous_env =
      snapshot_env(
        ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]
      )

    Application.delete_env(:backplane, :claude_code_monitor_req_options)
    System.put_env("HTTP_PROXY", "http://localhost:#{port}")
    System.delete_env("http_proxy")
    System.delete_env("HTTPS_PROXY")
    System.delete_env("https_proxy")
    System.delete_env("ALL_PROXY")
    System.delete_env("all_proxy")
    System.put_env("NO_PROXY", "localhost,127.0.0.1")
    System.put_env("no_proxy", "localhost,127.0.0.1")

    on_exit(fn ->
      if previous_opts do
        Application.put_env(:backplane, :claude_code_monitor_req_options, previous_opts)
      else
        Application.delete_env(:backplane, :claude_code_monitor_req_options)
      end

      restore_env(previous_env)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    assert {:ok, result} =
             ClaudeCode.fetch_oauth("sk-ant-oat01-usage", %{
               "api_url" => "http://api.anthropic.invalid/api/oauth/usage"
             })

    assert result.provider == "claude_code"
    assert result.usage["five_hour"]["utilization"] == 2.0
  end

  defp snapshot_env(names) do
    Map.new(names, fn name -> {name, System.get_env(name)} end)
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
