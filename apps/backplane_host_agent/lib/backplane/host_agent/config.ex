defmodule Backplane.HostAgent.Config do
  @moduledoc """
  Loads host agent configuration from YAML.

  Default location: `~/.config/backplane/host_agent.yaml`.
  Override with the `BACKPLANE_HOST_AGENT_CONFIG` env var or by passing
  an explicit path to `load/1`.
  """

  @default_http_port 4222

  defstruct [
    :host_id,
    :machine_name,
    :hub_url,
    :socket_url,
    :token,
    :manifest_path,
    :work_dir,
    :memory,
    :capture,
    :telemetry,
    interval_ms: 60_000,
    targets: [],
    http_bind: "127.0.0.1",
    http_port: @default_http_port
  ]

  @socket_path "/host-agent/socket/websocket"
  @default_filename "host_agent.yaml"

  @doc "Resolves the default config path: `~/.config/backplane/host_agent.yaml`."
  def default_path do
    Path.join([config_home(), "backplane", @default_filename])
  end

  @doc "Returns a sample YAML config body."
  def sample_yaml(opts \\ []) do
    host_id = Keyword.get(opts, :host_id, "REPLACE_WITH_AGENT_ID")
    machine_name = Keyword.get(opts, :machine_name, hostname())
    hub_url = Keyword.get(opts, :hub_url, "http://localhost:4220")
    work_dir = Keyword.get(opts, :work_dir, default_work_dir())
    manifest_path = Keyword.get(opts, :manifest_path, Path.join(work_dir, "manifest.json"))

    """
    # Backplane host agent configuration
    agent:
      host_id: #{host_id}
      machine_name: #{machine_name}
      hub_url: #{hub_url}
      token: REPLACE_WITH_AUTH_TOKEN
      interval_ms: 60000
      manifest_path: #{manifest_path}
      work_dir: #{work_dir}

      # Local Memory HTTP API. Bind 127.0.0.1 and set http_port to expose
      # /memory/:agent_id/mcp and /memory/:agent_id/call/:method to processes
      # on this host. Set http_port to 0 to disable.
      http_bind: 127.0.0.1
      http_port: #{@default_http_port}

    memory:
      enabled: true
      db_path: #{Path.join(work_dir, "memory/host_agent_memory.db")}
      bound_scope: proj_local
      local_ttl_days: 90
      sync_interval_ms: 5000
      sync_batch_size: 50
      max_attempts: 5
      tombstone_relearn: block
      # Server-triggered imports name an opaque profile; only this host config
      # resolves that profile to a path and approved roots.
      import_profiles:
        claude_default:
          path: #{Path.join(System.user_home!(), ".claude/projects")}
          approved_roots:
            - #{Path.join(System.user_home!(), ".claude/projects")}

    capture:
      enabled: true
      db_path: #{Path.join(work_dir, "memory/capture_spool.db")}
      # Optional: name of an environment variable containing a Base64-encoded
      # 32-byte AES-256-GCM key. The key itself never belongs in this file.
      # encryption_key_env: BACKPLANE_CAPTURE_SPOOL_KEY
      # Lifecycle context injection is opt-in. Its synchronous request is
      # always capped at 1500ms and uses only a bounded volatile fallback cache.
      inject_context: false
      context_timeout_ms: 1200
      recall_cache_max_entries: 128
      recall_cache_max_bytes: 2097152
      recall_cache_ttl_ms: 900000
      upload_interval_ms: 5000
      batch_size: 100
      batch_bytes: 524288
      spool_max_bytes: 67108864
      spool_max_age_days: 30
      retry_base_ms: 1000
      retry_max_ms: 300000
      compaction_batch_size: 100

    telemetry:
      enabled: true
      dir: #{Path.join(work_dir, "telemetry")}
      sync_interval_ms: 10000
      sync_batch_size: 100
      retention_days: 14

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
    host_id = agent["host_id"]
    work_dir = expand_path(agent["work_dir"])
    http_port = parse_port(agent["http_port"])

    %__MODULE__{
      host_id: host_id,
      machine_name: agent["machine_name"],
      hub_url: hub_url,
      socket_url: socket_url(hub_url, host_id),
      token: agent["token"],
      interval_ms: agent["interval_ms"] || 60_000,
      manifest_path: expand_path(agent["manifest_path"]),
      work_dir: work_dir,
      http_bind: agent["http_bind"] || "127.0.0.1",
      http_port: http_port,
      memory: parse_memory(raw["memory"], work_dir, http_port),
      capture: parse_capture(raw["capture"], work_dir, http_port),
      telemetry: parse_telemetry(raw["telemetry"], work_dir),
      targets: parse_targets(raw["targets"] || [])
    }
  end

  defp parse_port(nil), do: @default_http_port
  defp parse_port(port) when is_integer(port) and port >= 0, do: port
  defp parse_port(_), do: nil

  defp parse_targets(targets) when is_list(targets) do
    Enum.map(targets, fn target ->
      %{
        name: target["name"],
        runtime: target["runtime"],
        path: expand_path(target["path"]),
        enabled: target["enabled"] != false
      }
    end)
  end

  defp parse_targets(_targets), do: []

  defp parse_memory(raw, work_dir, http_port) do
    raw = if is_map(raw), do: raw, else: %{}

    %{
      enabled: parse_bool(raw["enabled"], memory_enabled_by_default?(http_port)),
      db_path: expand_path(raw["db_path"] || default_memory_db_path(work_dir)),
      bound_scope: parse_non_empty_string(raw["bound_scope"], "proj_local"),
      local_ttl_days: parse_positive_int(raw["local_ttl_days"], 90),
      sync_interval_ms: parse_positive_int(raw["sync_interval_ms"], 5_000),
      sync_batch_size: parse_positive_int(raw["sync_batch_size"], 50),
      max_attempts: parse_positive_int(raw["max_attempts"], 5),
      tombstone_relearn: parse_tombstone_relearn(raw["tombstone_relearn"]),
      import_profiles: parse_import_profiles(raw["import_profiles"])
    }
  end

  defp parse_import_profiles(profiles) when is_map(profiles) do
    profiles
    |> Enum.filter(fn {name, value} ->
      is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/, name) and
        is_map(value)
    end)
    |> Map.new(fn {name, value} ->
      {name,
       %{
         path: expand_path(value["path"]),
         approved_roots:
           value
           |> Map.get("approved_roots", [])
           |> List.wrap()
           |> Enum.filter(&is_binary/1)
           |> Enum.map(&expand_path/1),
         allow_symlinks: parse_bool(value["allow_symlinks"], false),
         max_depth: parse_positive_int(value["max_depth"], 12)
       }}
    end)
  end

  defp parse_import_profiles(_profiles), do: %{}

  defp memory_enabled_by_default?(port) when is_integer(port) and port > 0, do: true
  defp memory_enabled_by_default?(_port), do: false

  defp default_memory_db_path(work_dir) do
    base_dir = work_dir || default_work_dir()
    Path.join(base_dir, "memory/host_agent_memory.db")
  end

  defp parse_capture(raw, work_dir, http_port) do
    raw = if is_map(raw), do: raw, else: %{}
    retry_base_ms = parse_positive_int(raw["retry_base_ms"], 1_000)
    retry_max_ms = max(parse_positive_int(raw["retry_max_ms"], 300_000), retry_base_ms)

    %{
      enabled: parse_bool(raw["enabled"], memory_enabled_by_default?(http_port)),
      db_path: parse_capture_db_path(raw["db_path"], work_dir),
      encryption_key_env: parse_non_empty_string(raw["encryption_key_env"], nil),
      inject_context: parse_bool(raw["inject_context"], false),
      context_timeout_ms: parse_bounded_positive_int(raw["context_timeout_ms"], 1_200, 1_500),
      recall_cache_max_entries: parse_positive_int(raw["recall_cache_max_entries"], 128),
      recall_cache_max_bytes: parse_positive_int(raw["recall_cache_max_bytes"], 2 * 1024 * 1024),
      recall_cache_ttl_ms: parse_positive_int(raw["recall_cache_ttl_ms"], 15 * 60 * 1_000),
      upload_interval_ms: parse_positive_int(raw["upload_interval_ms"], 5_000),
      batch_size: parse_bounded_positive_int(raw["batch_size"], 100, 100),
      batch_bytes: parse_bounded_positive_int(raw["batch_bytes"], 512 * 1024, 512 * 1024),
      spool_max_bytes: parse_positive_int(raw["spool_max_bytes"], 64 * 1024 * 1024),
      spool_max_age_days: parse_positive_int(raw["spool_max_age_days"], 30),
      retry_base_ms: retry_base_ms,
      retry_max_ms: retry_max_ms,
      compaction_batch_size: parse_positive_int(raw["compaction_batch_size"], 100)
    }
  end

  defp parse_capture_db_path(path, work_dir) do
    case parse_non_empty_string(path, nil) do
      nil -> Path.join(work_dir || default_work_dir(), "memory/capture_spool.db")
      path -> expand_path(path)
    end
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_value, default), do: default

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_positive_int(_value, default), do: default

  defp parse_bounded_positive_int(value, _default, maximum)
       when is_integer(value) and value > 0,
       do: min(value, maximum)

  defp parse_bounded_positive_int(_value, default, _maximum), do: default

  defp parse_non_empty_string(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp parse_non_empty_string(_value, default), do: default

  defp parse_tombstone_relearn("allow_with_log"), do: "allow_with_log"
  defp parse_tombstone_relearn(_value), do: "block"

  defp parse_telemetry(raw, work_dir) do
    raw = if is_map(raw), do: raw, else: %{}

    %{
      enabled: parse_bool(raw["enabled"], true),
      dir: expand_path(raw["dir"] || default_telemetry_dir(work_dir)),
      sync_interval_ms: parse_positive_int(raw["sync_interval_ms"], 10_000),
      sync_batch_size: parse_positive_int(raw["sync_batch_size"], 100),
      retention_days: parse_positive_int(raw["retention_days"], 14)
    }
  end

  defp default_telemetry_dir(work_dir) do
    base_dir = work_dir || default_work_dir()
    Path.join(base_dir, "telemetry")
  end

  defp expand_path(path) when is_binary(path), do: Path.expand(path)
  defp expand_path(path), do: path

  defp trim_trailing_slash(nil), do: nil
  defp trim_trailing_slash(url), do: String.trim_trailing(url, "/")

  defp socket_url("http://" <> rest, host_id), do: "ws://" <> rest <> socket_path(host_id)
  defp socket_url("https://" <> rest, host_id), do: "wss://" <> rest <> socket_path(host_id)
  defp socket_url(_hub_url, _host_id), do: nil

  defp socket_path(host_id) when is_binary(host_id) and host_id != "" do
    @socket_path <> "?host_id=" <> URI.encode_www_form(host_id)
  end

  defp socket_path(_host_id), do: @socket_path

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
