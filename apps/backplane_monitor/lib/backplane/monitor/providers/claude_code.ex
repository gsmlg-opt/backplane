defmodule Backplane.Monitor.Providers.ClaudeCode do
  @moduledoc """
  Fetches Claude Code usage by running a stored JavaScript fetch script.

  Script credentials are expected to contain JavaScript that awaits a fetch
  response, awaits `response.json()`, and returns the decoded usage payload.
  """

  @provider "claude_code"
  @default_timeout 30_000
  @proxy_env_vars ~w(
    HTTP_PROXY
    HTTPS_PROXY
    ALL_PROXY
    NO_PROXY
    http_proxy
    https_proxy
    all_proxy
    no_proxy
  )

  @doc "Run a Claude Code usage script through Denox and return the decoded payload."
  @spec fetch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(script, config \\ %{}) when is_binary(script) and is_map(config) do
    timeout = timeout_ms(config)

    with {:ok, runtime} <- runtime(),
         {:ok, usage} <- run_script(runtime, script, config, timeout) do
      {:ok, %{provider: @provider, usage: usage}}
    end
  end

  defp runtime do
    case Denox.runtime(permissions: [allow_net: true, allow_env: @proxy_env_vars]) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, reason} -> {:error, {:script_runtime_failed, reason}}
    end
  end

  defp run_script(runtime, script, config, timeout) do
    task = Denox.eval_async_decode(runtime, script_module(script, config))

    try do
      case Task.await(task, timeout) do
        {:ok, usage} -> {:ok, usage}
        {:error, reason} -> {:error, {:script_failed, reason}}
      end
    catch
      :exit, {:timeout, _} -> {:error, {:script_failed, :timeout}}
      :exit, reason -> {:error, {:script_failed, reason}}
    end
  end

  defp script_module(script, config) do
    config_json = Jason.encode!(config)
    script = String.trim(script)

    cond do
      String.contains?(script, "export default") ->
        """
        const config = #{config_json};
        const planConfig = config;
        #{script}
        """

      bare_fetch_script?(script) ->
        """
        const config = #{config_json};
        const planConfig = config;
        const response = await (#{strip_trailing_semicolon(script)});
        const responseForDiagnostics = response.clone();
        let usage;

        try {
          usage = await response.json();
        } catch (error) {
          const contentType = response.headers.get("content-type") || "unknown";
          const body = await responseForDiagnostics.text();
          throw new Error(`Expected JSON response but got status ${response.status} ${contentType}: ${body.slice(0, 200)}`);
        }

        export default usage;
        """

      true ->
        """
        const config = #{config_json};
        const planConfig = config;

        export default await (async () => {
        #{script}
        })();
        """
    end
  end

  defp bare_fetch_script?(script) do
    String.starts_with?(script, "fetch(") and not String.contains?(script, "return")
  end

  defp strip_trailing_semicolon(script) do
    script
    |> String.trim()
    |> String.trim_trailing(";")
  end

  defp timeout_ms(%{"timeout_ms" => timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp timeout_ms(%{"timeout_ms" => timeout}) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> @default_timeout
    end
  end

  defp timeout_ms(_config), do: @default_timeout
end
