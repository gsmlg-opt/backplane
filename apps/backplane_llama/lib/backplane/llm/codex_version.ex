defmodule Backplane.LLM.CodexVersion do
  @moduledoc """
  Resolves the Codex client version used for Codex model discovery.

  An explicit application setting or environment variable takes precedence over
  the latest GitHub release. The locally installed CLI and compatibility
  sentinel are fallbacks when GitHub is unavailable.
  """

  @default "0.0.0"

  @spec current() :: String.t()
  def current do
    Application.get_env(:backplane, :openai_codex_client_version) ||
      System.get_env("OPENAI_CODEX_CLIENT_VERSION") ||
      latest_release_version() || installed_cli_version() || @default
  end

  @spec parse_cli_output(String.t()) :: String.t() | nil
  def parse_cli_output(output) when is_binary(output) do
    case Regex.run(~r/(?<!\d)(\d+\.\d+\.\d+)(?!\d)/, output, capture: :all_but_first) do
      [version] -> version
      _ -> nil
    end
  end

  def parse_cli_output(_output), do: nil

  @spec parse_release(map()) :: String.t() | nil
  def parse_release(%{} = release) do
    parse_cli_output(to_string(release["name"] || release["tag_name"] || ""))
  end

  def parse_release(_release), do: nil

  defp latest_release_version do
    if test_env?() do
      nil
    else
      url = "https://api.github.com/repos/openai/codex/releases/latest"

      with {:ok, %{status: status, body: body}} when status in 200..299 <-
             github_release_request(url),
           version when is_binary(version) <- parse_release(body) do
        version
      else
        _ -> nil
      end
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp github_release_request(url) do
    Req.get(url,
      headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "backplane"}],
      receive_timeout: 5_000,
      retry: false
    )
  rescue
    _ -> {:error, :github_unavailable}
  end

  defp installed_cli_version do
    with executable when is_binary(executable) <- System.find_executable("codex"),
         {output, 0} <- System.cmd(executable, ["--version"], stderr_to_stdout: true),
         version when is_binary(version) <- parse_cli_output(output) do
      version
    else
      _ -> nil
    end
  end
end
