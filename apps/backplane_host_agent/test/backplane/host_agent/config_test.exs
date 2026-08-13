defmodule Backplane.HostAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Config

  @tag :tmp_dir
  test "loads agent config and computes websocket URL", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")
    manifest_path = Path.join(tmp_dir, "manifest.json")
    work_dir = Path.join(tmp_dir, "work")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      interval_ms: 15000
      manifest_path: #{manifest_path}
      work_dir: #{work_dir}

    targets:
      - name: agents
        runtime: agent-skills
        path: #{Path.join(tmp_dir, "skills")}
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.machine_name == "t430"
    assert config.host_id == "host-123"
    assert config.socket_url == "ws://localhost:4220/host-agent/socket/websocket?host_id=host-123"
    assert config.interval_ms == 15_000

    assert [
             %{
               name: "agents",
               runtime: "agent-skills",
               path: _target_path,
               enabled: true
             }
           ] = config.targets
  end

  @tag :tmp_dir
  test "parses http_bind and http_port for the local memory API", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{Path.join(tmp_dir, "work")}
      http_bind: 0.0.0.0
      http_port: 4321
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.http_bind == "0.0.0.0"
    assert config.http_port == 4321
  end

  @tag :tmp_dir
  test "http_port defaults to the local memory API port and http_bind to localhost", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{Path.join(tmp_dir, "work")}
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.http_bind == "127.0.0.1"
    assert config.http_port == 4222
  end

  test "sample config includes the local memory API listen port" do
    sample = Config.sample_yaml(machine_name: "t430")

    assert sample =~ "http_bind: 127.0.0.1"
    assert sample =~ "host_id: REPLACE_WITH_AGENT_ID"
    assert sample =~ "\n  http_port: 4222\n"
    assert sample =~ "\nmemory:\n"
    assert sample =~ "\ncapture:\n"
    assert sample =~ "capture_spool.db"
    assert sample =~ "upload_interval_ms: 5000"
    assert sample =~ "batch_size: 100"
    assert sample =~ "batch_bytes: 524288"
    assert sample =~ "db_path:"
    assert sample =~ "local_ttl_days: 90"
    assert sample =~ "import_profiles:"
    assert sample =~ "claude_default:"
    assert sample =~ "\ntelemetry:\n"
    assert sample =~ "sync_interval_ms: 10000"
    assert sample =~ "retention_days: 14"
    refute sample =~ "# http_port"
  end

  @tag :tmp_dir
  test "parses opaque import profiles while retaining paths only in host config", %{tmp_dir: dir} do
    path = Path.join(dir, "sessions")
    config_path = Path.join(dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      host_id: host-123
      work_dir: #{dir}
    memory:
      import_profiles:
        project_history:
          path: #{path}
          approved_roots:
            - #{dir}
          max_depth: 7
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.memory.import_profiles == %{
             "project_history" => %{
               path: path,
               approved_roots: [dir],
               allow_symlinks: false,
               max_depth: 7
             }
           }
  end

  @tag :tmp_dir
  test "defaults memory config from work_dir when HTTP memory API is enabled", %{tmp_dir: tmp_dir} do
    work_dir = Path.join(tmp_dir, "work")
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{work_dir}
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.memory == %{
             enabled: true,
             db_path: Path.join(work_dir, "memory/host_agent_memory.db"),
             bound_scope: "proj_local",
             local_ttl_days: 90,
             sync_interval_ms: 5_000,
             sync_batch_size: 50,
             max_attempts: 5,
             import_profiles: %{},
             tombstone_relearn: "block"
           }

    assert config.capture == %{
             enabled: true,
             db_path: Path.join(work_dir, "memory/capture_spool.db"),
             encryption_key_env: nil,
             inject_context: false,
             context_timeout_ms: 1_200,
             recall_cache_max_entries: 128,
             recall_cache_max_bytes: 2 * 1024 * 1024,
             recall_cache_ttl_ms: 15 * 60 * 1_000,
             upload_interval_ms: 5_000,
             batch_size: 100,
             batch_bytes: 524_288,
             spool_max_bytes: 64 * 1024 * 1024,
             spool_max_age_days: 30,
             retry_base_ms: 1_000,
             retry_max_ms: 300_000,
             compaction_batch_size: 100
           }

    assert config.telemetry == %{
             enabled: true,
             dir: Path.join(work_dir, "telemetry"),
             sync_interval_ms: 10_000,
             sync_batch_size: 100,
             retention_days: 14
           }
  end

  @tag :tmp_dir
  test "parses explicit capture config and safe fallbacks", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")
    work_dir = Path.join(tmp_dir, "work")
    capture_path = Path.join(tmp_dir, "capture.db")

    File.write!(config_path, """
    agent:
      host_id: host-123
      work_dir: #{work_dir}
      http_port: 0

    capture:
      enabled: true
      db_path: #{capture_path}
      encryption_key_env: BACKPLANE_CAPTURE_SPOOL_KEY
      inject_context: true
      context_timeout_ms: 9000
      recall_cache_max_entries: 7
      recall_cache_max_bytes: 8192
      recall_cache_ttl_ms: 60000
      upload_interval_ms: 250
      batch_size: 8
      batch_bytes: 4096
      spool_max_bytes: 1048576
      spool_max_age_days: 7
      retry_base_ms: 250
      retry_max_ms: 4000
      compaction_batch_size: 25
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.capture == %{
             enabled: true,
             db_path: capture_path,
             encryption_key_env: "BACKPLANE_CAPTURE_SPOOL_KEY",
             inject_context: true,
             context_timeout_ms: 1_500,
             recall_cache_max_entries: 7,
             recall_cache_max_bytes: 8_192,
             recall_cache_ttl_ms: 60_000,
             upload_interval_ms: 250,
             batch_size: 8,
             batch_bytes: 4096,
             spool_max_bytes: 1_048_576,
             spool_max_age_days: 7,
             retry_base_ms: 250,
             retry_max_ms: 4_000,
             compaction_batch_size: 25
           }

    File.write!(config_path, """
    agent:
      host_id: host-123
      work_dir: #{work_dir}
      http_port: 0

    capture:
      enabled: invalid
      db_path: ""
      upload_interval_ms: 0
      batch_size: -1
      batch_bytes: nope
      spool_max_bytes: 0
      spool_max_age_days: old
      retry_base_ms: -1
      retry_max_ms: 0
      compaction_batch_size: no
    """)

    assert {:ok, invalid} = Config.load(config_path)

    assert invalid.capture == %{
             enabled: false,
             db_path: Path.join(work_dir, "memory/capture_spool.db"),
             encryption_key_env: nil,
             inject_context: false,
             context_timeout_ms: 1_200,
             recall_cache_max_entries: 128,
             recall_cache_max_bytes: 2 * 1024 * 1024,
             recall_cache_ttl_ms: 15 * 60 * 1_000,
             upload_interval_ms: 5_000,
             batch_size: 100,
             batch_bytes: 524_288,
             spool_max_bytes: 64 * 1024 * 1024,
             spool_max_age_days: 30,
             retry_base_ms: 1_000,
             retry_max_ms: 300_000,
             compaction_batch_size: 100
           }

    File.write!(config_path, """
    agent:
      host_id: host-123
      work_dir: #{work_dir}

    capture:
      batch_size: 101
      batch_bytes: 524289
    """)

    assert {:ok, clamped} = Config.load(config_path)
    assert clamped.capture.batch_size == 100
    assert clamped.capture.batch_bytes == 524_288
  end

  @tag :tmp_dir
  test "capture defaults disabled with the local HTTP listener", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      host_id: host-123
      work_dir: #{Path.join(tmp_dir, "work")}
      http_port: 0
    """)

    assert {:ok, config} = Config.load(config_path)
    refute config.capture.enabled
  end

  @tag :tmp_dir
  test "parses explicit telemetry config and expands dir", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")
    telemetry_dir = Path.join(tmp_dir, "trace-files")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{Path.join(tmp_dir, "work")}

    telemetry:
      enabled: false
      dir: #{telemetry_dir}
      sync_interval_ms: 250
      sync_batch_size: 8
      retention_days: 3
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.telemetry == %{
             enabled: false,
             dir: telemetry_dir,
             sync_interval_ms: 250,
             sync_batch_size: 8,
             retention_days: 3
           }
  end

  @tag :tmp_dir
  test "parses explicit memory config and expands db_path", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")
    db_path = Path.join(tmp_dir, "memory.db")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{Path.join(tmp_dir, "work")}
      http_port: 0

    memory:
      enabled: true
      db_path: #{db_path}
      bound_scope: proj_custom
      local_ttl_days: 30
      sync_interval_ms: 250
      sync_batch_size: 10
      max_attempts: 2
      tombstone_relearn: allow_with_log
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.memory == %{
             enabled: true,
             db_path: db_path,
             bound_scope: "proj_custom",
             local_ttl_days: 30,
             sync_interval_ms: 250,
             sync_batch_size: 10,
             max_attempts: 2,
             import_profiles: %{},
             tombstone_relearn: "allow_with_log"
           }
  end

  @tag :tmp_dir
  test "expands tilde paths from config instead of treating them as relative", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: http://localhost:4220
      host_id: host-123
      token: secret-token
      manifest_path: ~/.local/share/backplane/host_agent/manifest.json
      work_dir: ~/.local/share/backplane/host_agent

    targets:
      - name: agents
        runtime: agent-skills
        path: ~/.local/share/backplane/host_agent/skills
    """)

    assert {:ok, config} = Config.load(config_path)

    assert config.manifest_path ==
             Path.expand("~/.local/share/backplane/host_agent/manifest.json")

    assert config.work_dir == Path.expand("~/.local/share/backplane/host_agent")

    assert [%{path: path}] = config.targets
    assert path == Path.expand("~/.local/share/backplane/host_agent/skills")
  end

  @tag :tmp_dir
  test "computes secure websocket URL for https hubs", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.yaml")

    File.write!(config_path, """
    agent:
      machine_name: t430
      hub_url: https://example.test/
      host_id: host-123
      token: secret-token
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      work_dir: #{Path.join(tmp_dir, "work")}
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.socket_url == "wss://example.test/host-agent/socket/websocket?host_id=host-123"
  end

  test "default_path uses XDG_CONFIG_HOME when set" do
    System.put_env("XDG_CONFIG_HOME", "/tmp/xdg-test")

    on_exit(fn -> System.delete_env("XDG_CONFIG_HOME") end)

    assert Config.default_path() == "/tmp/xdg-test/backplane/host_agent.yaml"
  end

  test "resolved_path honors BACKPLANE_HOST_AGENT_CONFIG override" do
    System.put_env("BACKPLANE_HOST_AGENT_CONFIG", "/tmp/custom.yaml")

    on_exit(fn -> System.delete_env("BACKPLANE_HOST_AGENT_CONFIG") end)

    assert Config.resolved_path() == "/tmp/custom.yaml"
  end

  @tag :tmp_dir
  test "load_default returns :missing when file does not exist", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "absent.yaml")
    System.put_env("BACKPLANE_HOST_AGENT_CONFIG", path)
    on_exit(fn -> System.delete_env("BACKPLANE_HOST_AGENT_CONFIG") end)

    assert {:error, {:missing, ^path}} = Config.load_default()
  end

  @tag :tmp_dir
  test "write_sample creates the file and is idempotent", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "config", "host_agent.yaml"])

    assert :ok = Config.write_sample(path)
    assert File.exists?(path)
    assert {:ok, :exists} = Config.write_sample(path)
  end
end
