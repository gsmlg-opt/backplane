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

  test "fetch/2 runs a fetch script and returns response JSON usage" do
    script =
      usage_script(%{
        "subscription" => "max",
        "tokens" => %{"used" => 42, "limit" => 100}
      })

    assert {:ok, result} = ClaudeCode.fetch(script)
    assert result.provider == "claude_code"
    assert result.usage["subscription"] == "max"
    assert result.usage["tokens"]["used"] == 42
    assert result.usage["tokens"]["limit"] == 100
  end

  test "fetch/2 exposes plan config to the script" do
    script = """
    const response = await fetch(config.usage_url);
    const data = await response.json();
    return data;
    """

    usage = %{"plan" => "team", "remaining" => 17}
    config = %{"usage_url" => data_url(usage)}

    assert {:ok, result} = ClaudeCode.fetch(script, config)
    assert result.usage == usage
  end

  test "fetch/2 accepts a bare fetch script and returns response JSON" do
    usage = %{"subscription" => "pro", "usage" => %{"current" => 5}}

    script = """
    fetch("#{data_url(usage)}");
    """

    assert {:ok, result} = ClaudeCode.fetch(script)
    assert result.usage == usage
  end

  test "fetch/2 reports non-JSON responses for bare fetch scripts" do
    script = """
    fetch("data:text/html;base64,#{Base.encode64("<!DOCTYPE html><title>Login</title>")}");
    """

    assert {:error, {:script_failed, reason}} = ClaudeCode.fetch(script)
    assert reason =~ "Expected JSON response"
    assert reason =~ "text/html"
    assert reason =~ "<!DOCTYPE html>"
  end

  test "fetch/2 allows scripts to read proxy environment variables" do
    script = """
    return {proxy: Deno.env.get("HTTP_PROXY") || Deno.env.get("http_proxy") || null};
    """

    assert {:ok, result} = ClaudeCode.fetch(script)
    assert Map.has_key?(result.usage, "proxy")
  end

  test "fetch/2 returns a script error when the script fails" do
    assert {:error, {:script_failed, reason}} = ClaudeCode.fetch("throw new Error('bad script')")
    assert is_binary(reason)
    assert reason =~ "bad script"
  end

  defp usage_script(usage) do
    """
    const response = await fetch("#{data_url(usage)}");
    const data = await response.json();
    return data;
    """
  end

  defp data_url(payload) do
    "data:application/json;base64,#{payload |> Jason.encode!() |> Base.encode64()}"
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
