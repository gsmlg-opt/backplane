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
      http_port: 4221
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.http_bind == "0.0.0.0"
    assert config.http_port == 4221
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
    assert config.http_port == 4221
  end

  test "sample config includes the local memory API listen port" do
    sample = Config.sample_yaml(machine_name: "t430")

    assert sample =~ "http_bind: 127.0.0.1"
    assert sample =~ "host_id: REPLACE_WITH_AGENT_ID"
    assert sample =~ "\n  http_port: 4221\n"
    assert sample =~ "\nmemory:\n"
    assert sample =~ "db_path:"
    assert sample =~ "local_ttl_days: 90"
    refute sample =~ "# http_port"
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
             tombstone_relearn: "block"
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
