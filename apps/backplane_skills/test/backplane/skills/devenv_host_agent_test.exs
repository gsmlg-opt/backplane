Code.require_file(Path.expand("../../../../../scripts/devenv_host_agent.ex", __DIR__))

defmodule Backplane.Scripts.DevenvHostAgentTest do
  use BackplaneSkills.DataCase, async: false

  import Bitwise, only: [band: 2]

  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.Entitlement
  alias Backplane.Scripts.DevenvHostAgent
  alias Backplane.Skills.{AgentManage, Hosts, HostAuthToken}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
    %{config_path: Path.join([tmp_dir, ~s(host agent # "local"), "host_agent.yaml"])}
  end

  test "creates an authenticated host and matching private local configuration", %{
    config_path: path
  } do
    assert {:ok, metadata} = DevenvHostAgent.prepare(path)
    assert metadata.config_path == path
    assert String.starts_with?(metadata.name, "backplane-devenv-")
    assert String.starts_with?(metadata.memory_scope, "devenv_")

    host = Hosts.get_host(metadata.host_id)
    assert host.name == metadata.name
    assert host.memory_scope == metadata.memory_scope
    assert [auth_token_id] = Hosts.auth_token_ids_for_host(host)
    assert {:ok, config} = YamlElixir.read_from_file(path)
    token = config["agent"]["token"]

    assert {:ok, verified, auth_token} = Hosts.verify_token(token)
    assert verified.id == host.id
    assert auth_token.id == auth_token_id
    assert {:ok, authenticated, cached_token} = AgentManage.authenticate(host.id, token)
    assert authenticated.id == host.id
    assert cached_token.id == auth_token_id

    assert {:ok, partition} =
             MemorySpaces.resolve_host_partition(
               host.id,
               config["memory"]["bound_scope"],
               "private"
             )

    assert partition.scope == host.memory_scope
    assert config["agent"]["host_id"] == host.id
    assert config["agent"]["machine_name"] == host.name
    assert config["agent"]["hub_url"] == "http://127.0.0.1:4220"
    assert config["agent"]["http_bind"] == "127.0.0.1"
    assert config["agent"]["http_port"] == 4222
    assert config["agent"]["work_dir"] == Path.dirname(path)
    assert Path.dirname(config["agent"]["manifest_path"]) == Path.dirname(path)
    assert Path.dirname(config["memory"]["db_path"]) == Path.dirname(path)
    assert config["memory"]["enabled"] == true
    assert config["targets"] == []
    refute Map.has_key?(metadata, :token)
    refute inspect(metadata) =~ token
    assert band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
  end

  test "repeat setup and missing configuration reuse the same identity, token and partition", %{
    config_path: path
  } do
    assert {:ok, metadata} = DevenvHostAgent.prepare(path)
    contents = File.read!(path)
    token_ids = Hosts.auth_token_ids_for_host(metadata.host_id)

    assert {:ok, partition} =
             MemorySpaces.resolve_host_partition(
               metadata.host_id,
               metadata.memory_scope,
               "private"
             )

    for remove_config? <- [false, true] do
      if remove_config?, do: File.rm!(path)
      assert {:ok, ^metadata} = DevenvHostAgent.prepare(path)
      assert File.read!(path) == contents
      assert Hosts.auth_token_ids_for_host(metadata.host_id) == token_ids

      assert {:ok, ^partition} =
               MemorySpaces.resolve_host_partition(
                 metadata.host_id,
                 metadata.memory_scope,
                 "private"
               )
    end

    assert length(Hosts.list_hosts()) == 1
    assert Repo.aggregate(HostAuthToken, :count) == 1

    assert Repo.aggregate(
             from(entitlement in Entitlement, where: entitlement.host_id == ^metadata.host_id),
             :count
           ) == 1
  end

  test "uses the registered scope when regenerating configuration", %{config_path: path} do
    assert {:ok, metadata} = DevenvHostAgent.prepare(path)
    host = Hosts.get_host(metadata.host_id)
    token_ids = Hosts.auth_token_ids_for_host(host)
    assert {:ok, updated} = Hosts.update_agent(host, %{memory_scope: "registered:custom"})

    assert {:ok, refreshed} = DevenvHostAgent.prepare(path)
    assert refreshed.host_id == host.id
    assert refreshed.memory_scope == updated.memory_scope
    assert Hosts.auth_token_ids_for_host(host) == token_ids
    assert {:ok, config} = YamlElixir.read_from_file(path)
    assert config["memory"]["bound_scope"] == "registered:custom"

    assert {:ok, %{scope: "registered:custom"}} =
             MemorySpaces.resolve_host_partition(
               host.id,
               config["memory"]["bound_scope"],
               "private"
             )
  end

  test "repairs a generated host without an assigned token", %{config_path: path} do
    assert {:ok, metadata} = DevenvHostAgent.prepare(path)
    host = Hosts.get_host(metadata.host_id)
    assert [old_token_id] = Hosts.auth_token_ids_for_host(host)
    assert {:ok, old_config} = YamlElixir.read_from_file(path)
    assert {:ok, _revoked} = Hosts.revoke_auth_token_for_agent(host, old_token_id)

    assert {:ok, ^metadata} = DevenvHostAgent.prepare(path)
    assert [new_token_id] = Hosts.auth_token_ids_for_host(host)
    refute new_token_id == old_token_id
    assert {:ok, config} = YamlElixir.read_from_file(path)
    refute config["agent"]["token"] == old_config["agent"]["token"]

    assert {:ok, authenticated, auth_token} =
             AgentManage.authenticate(host.id, config["agent"]["token"])

    assert authenticated.id == host.id
    assert auth_token.id == new_token_id
    assert :error = Hosts.verify_token(old_config["agent"]["token"])
    assert length(Hosts.list_hosts()) == 1
    assert Repo.aggregate(HostAuthToken, :count) == 1
  end
end
