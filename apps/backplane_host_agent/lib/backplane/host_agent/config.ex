defmodule Backplane.HostAgent.Config do
  @moduledoc """
  Loads host agent configuration from TOML.
  """

  defstruct [
    :machine_name,
    :hub_url,
    :socket_url,
    :token,
    :manifest_path,
    :work_dir,
    interval_ms: 60_000,
    targets: []
  ]

  @socket_path "/host-agent/socket/websocket"

  def load(path) do
    with {:ok, raw} <- Toml.decode_file(path) do
      {:ok, parse(raw)}
    end
  end

  defp parse(raw) do
    agent = raw["agent"] || %{}
    hub_url = trim_trailing_slash(agent["hub_url"])

    %__MODULE__{
      machine_name: agent["machine_name"],
      hub_url: hub_url,
      socket_url: socket_url(hub_url),
      token: agent["token"],
      interval_ms: agent["interval_ms"] || 60_000,
      manifest_path: agent["manifest_path"],
      work_dir: agent["work_dir"],
      targets: parse_targets(raw["targets"] || [])
    }
  end

  defp parse_targets(targets) when is_list(targets) do
    Enum.map(targets, fn target ->
      %{
        name: target["name"],
        runtime: target["runtime"],
        path: target["path"],
        enabled: target["enabled"] != false
      }
    end)
  end

  defp parse_targets(_targets), do: []

  defp trim_trailing_slash(nil), do: nil
  defp trim_trailing_slash(url), do: String.trim_trailing(url, "/")

  defp socket_url("http://" <> rest), do: "ws://" <> rest <> @socket_path
  defp socket_url("https://" <> rest), do: "wss://" <> rest <> @socket_path
  defp socket_url(_hub_url), do: nil
end
