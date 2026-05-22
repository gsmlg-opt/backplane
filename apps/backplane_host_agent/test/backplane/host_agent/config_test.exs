defmodule Backplane.HostAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Config

  @tag :tmp_dir
  test "loads agent config and computes websocket URL", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.toml")
    manifest_path = Path.join(tmp_dir, "manifest.json")
    work_dir = Path.join(tmp_dir, "work")

    File.write!(config_path, """
    [agent]
    machine_name = "t430"
    hub_url = "http://localhost:4220"
    token = "secret-token"
    interval_ms = 15000
    manifest_path = "#{manifest_path}"
    work_dir = "#{work_dir}"

    [[targets]]
    name = "agents"
    runtime = "agent-skills"
    path = "#{Path.join(tmp_dir, "skills")}"
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.machine_name == "t430"
    assert config.socket_url == "ws://localhost:4220/host-agent/socket/websocket"

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
  test "computes secure websocket URL for https hubs", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "agent.toml")

    File.write!(config_path, """
    [agent]
    machine_name = "t430"
    hub_url = "https://example.test/"
    token = "secret-token"
    manifest_path = "#{Path.join(tmp_dir, "manifest.json")}"
    work_dir = "#{Path.join(tmp_dir, "work")}"
    """)

    assert {:ok, config} = Config.load(config_path)
    assert config.socket_url == "wss://example.test/host-agent/socket/websocket"
  end
end
