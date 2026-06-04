defmodule Backplane.Monitor.Providers.ClaudeCodeTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.ClaudeCode

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
end
