defmodule Backplane.HostAgent.Config do
  @moduledoc """
  Loads host agent configuration from YAML.

  Default location: `~/.config/backplane/host_agent.yaml`.
  Override with the `BACKPLANE_HOST_AGENT_CONFIG` env var or by passing
  an explicit path to `load/1`.
  """

  defstruct [
    :machine_name,
    :hub_url,
    :socket_url,
    :token,
    :manifest_path,
    :work_dir,
    interval_ms: 60_000,
    targets: [],
    http_bind: "127.0.0.1",
    http_port: nil
  ]

  @socket_path "/host-agent/socket/websocket"
  @default_filename "host_agent.yaml"

  @doc "Resolves the default config path: `~/.config/backplane/host_agent.yaml`."
  def default_path do
    Path.join([config_home(), "backplane", @default_filename])
  end

  @doc "Returns a sample YAML config body."
  def sample_yaml(opts \\ []) do
    machine_name = Keyword.get(opts, :machine_name, hostname())
    hub_url = Keyword.get(opts, :hub_url, "http://localhost:4220")
    work_dir = Keyword.get(opts, :work_dir, default_work_dir())
    manifest_path = Keyword.get(opts, :manifest_path, Path.join(work_dir, "manifest.json"))

    """
    # Backplane host agent configuration
    agent:
      machine_name: #{machine_name}
      hub_url: #{hub_url}
      token: REPLACE_WITH_AUTH_TOKEN
      interval_ms: 60000
      manifest_path: #{manifest_path}
      work_dir: #{work_dir}

      # Local Memory HTTP API. Bind 127.0.0.1 and set http_port to expose
      # /memory/:agent_id/mcp and /memory/:agent_id/call/:method to processes
      # on this host. Leave http_port unset to disable.
      http_bind: 127.0.0.1
      # http_port: 4221

    targets:
      - name: agents
        runtime: agent-skills
        path: #{Path.join(work_dir, "skills")}
        enabled: true
    """
  end

  @doc """
  Loads config from `path`. Returns `{:ok, %Config{}}` or
  `{:error, reason}`.
  """
  def load(path) do
    with {:ok, raw} <- read_yaml(path) do
      {:ok, parse(raw)}
    end
  end

  @doc """
  Loads from the resolved path (`BACKPLANE_HOST_AGENT_CONFIG` env var
  falls back to `default_path/0`).

  Returns:
    * `{:ok, %Config{}}` — config loaded
    * `{:error, {:missing, path}}` — config file does not exist
    * `{:error, reason}` — parse/read failure
  """
  def load_default do
    path = resolved_path()

    case File.exists?(path) do
      true -> load(path)
      false -> {:error, {:missing, path}}
    end
  end

  @doc "Resolves the config path: env var if set, otherwise `default_path/0`."
  def resolved_path do
    case System.get_env("BACKPLANE_HOST_AGENT_CONFIG") do
      nil -> default_path()
      "" -> default_path()
      path -> Path.expand(path)
    end
  end

  @doc """
  Writes a sample config file at `path` if it does not already exist.

  Returns `:ok` on write, `{:ok, :exists}` if already present.
  """
  def write_sample(path, opts \\ []) do
    if File.exists?(path) do
      {:ok, :exists}
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, sample_yaml(opts))
      :ok
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      {:ok, _other} -> {:error, :invalid_yaml}
      {:error, reason} -> {:error, reason}
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
      http_bind: agent["http_bind"] || "127.0.0.1",
      http_port: parse_port(agent["http_port"]),
      targets: parse_targets(raw["targets"] || [])
    }
  end

  defp parse_port(nil), do: nil
  defp parse_port(port) when is_integer(port) and port >= 0, do: port
  defp parse_port(_), do: nil

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

  defp config_home do
    case System.get_env("XDG_CONFIG_HOME") do
      nil -> Path.expand("~/.config")
      "" -> Path.expand("~/.config")
      path -> path
    end
  end

  defp default_work_dir do
    Path.expand("~/.local/share/backplane/host_agent")
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "host"
    end
  end
end
