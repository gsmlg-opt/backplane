defmodule Backplane.Skills.AgentManageTest do
  use BackplaneSkills.DataCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Skills
  alias Backplane.Skills.{AgentManage, AgentPlugins, Assignments, Hosts}

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    previous_push_module = Application.get_env(:backplane_skills, :host_agent_channel_push_module)
    previous_timeout = Application.get_env(:backplane_skills, :host_agent_plugin_call_timeout)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})
    AgentManage.clear()

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
      restore_env(:host_agent_channel_push_module, previous_push_module)
      restore_env(:host_agent_plugin_call_timeout, previous_timeout)
      AgentManage.clear()
    end)
  end

  defmodule FakePluginPush do
    def push(channel, event, payload) do
      send(channel, {:agent_push, event, payload})
      :ok
    end
  end

  test "starts a manager when an agent is created with its initial token" do
    assert {:ok, host, auth_token, token} = Hosts.create_agent_with_token(%{"name" => "t430"})

    assert {:ok, revealed} = Hosts.reveal_auth_token(auth_token)
    assert revealed == token

    assert {:ok, entry} = AgentManage.get_agent(host.id)
    assert entry.host.id == host.id
    assert entry.status == :offline
    assert [%{id: token_id, name: "t430 token"}] = entry.tokens
    assert token_id == auth_token.id

    assert {:ok, authed_host, authed_token} = AgentManage.authenticate(host.id, token)
    assert authed_host.id == host.id
    assert authed_token.id == auth_token.id
  end

  test "bounded snapshots report truncation" do
    for name <- ~w(snapshot-a snapshot-b snapshot-c) do
      assert {:ok, _host, _auth_token, _token} =
               Hosts.create_agent_with_token(%{"name" => name})
    end

    assert %{entries: [_, _], truncated?: true} = AgentManage.list_agents(limit: 2)
    assert %{entries: [_], truncated?: true} = AgentManage.list_agents(limit: 1)
  end

  test "authenticates from the registry token cache without calling the manager" do
    assert {:ok, host, auth_token, token} = Hosts.create_agent_with_token(%{"name" => "t430"})

    assert [{manager_pid, %{host: cached_host, tokens: [cached_token]}}] =
             Registry.lookup(Backplane.Skills.AgentManage.Registry, host.id)

    assert cached_host.id == host.id
    assert cached_token.id == auth_token.id

    :sys.suspend(manager_pid)

    try do
      assert {:ok, authed_host, authed_token} = AgentManage.authenticate(host.id, token)
      assert authed_host.id == host.id
      assert authed_token.id == auth_token.id
    after
      :sys.resume(manager_pid)
    end
  end

  test "records live connection IP, runtime, config, and channel exits" do
    assert {:ok, host, auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "t430"})

    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
          _ -> :ok
        end
      end)

    metadata = %{connect_ip: "203.0.113.10", connect_ip_source: "x-real-ip"}
    assert :ok = AgentManage.register_connection(host, auth_token, pid, metadata)

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "status" => "syncing",
               "agent_version" => "0.3.0",
               "targets" => [%{"name" => "agents"}],
               "metadata" => %{"otp_release" => "28"},
               "capture" => %{
                 "connection_state" => "connected",
                 "spool_depth" => 3,
                 "spool_bytes" => 4096,
                 "oldest_event_age_ms" => 7000,
                 "captured_count" => 12,
                 "redacted_count" => 4,
                 "rejected_count" => 2,
                 "retry_count" => 1,
                 "dead_letter_count" => 1,
                 "upload_latency_ms" => 14,
                 "ack_latency_ms" => 9
               }
             })

    assert :ok =
             AgentManage.report_config(host.id, %{
               "agent" => %{"machine_name" => "t430"}
             })

    assert {:ok, entry} = AgentManage.get_agent(host.id)
    assert entry.status == :online
    assert entry.connect_ip == "203.0.113.10"
    assert entry.connect_ip_source == "x-real-ip"
    assert entry.auth_token_id == auth_token.id
    assert entry.runtime.agent_version == "0.3.0"
    assert entry.runtime.targets == [%{"name" => "agents"}]
    assert entry.runtime.metadata == %{"otp_release" => "28"}
    assert entry.runtime.capture["spool_depth"] == 3
    assert %DateTime{} = entry.last_heartbeat_at
    refute Map.has_key?(entry.runtime.capture, "payload")
    assert entry.config["agent"]["machine_name"] == "t430"

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{
                 "connection_state" => "disconnected",
                 "spool_depth" => nil,
                 "spool_bytes" => nil,
                 "oldest_event_age_ms" => nil,
                 "age_warning" => nil,
                 "captured_count" => nil,
                 "redacted_count" => nil,
                 "rejected_count" => nil,
                 "retry_count" => nil,
                 "dead_letter_count" => nil,
                 "upload_latency_ms" => nil,
                 "ack_latency_ms" => nil
               }
             })

    assert {:error, :invalid_payload} =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{"payload" => "must not cross the heartbeat boundary"}
             })

    assert {:error, :invalid_payload} =
             AgentManage.update_runtime(host.id, %{
               "metadata" => %{"payload" => "must not cross the heartbeat boundary"}
             })

    for invalid_version <- ["", %{"payload" => "content"}, ["0.3.0"], String.duplicate("v", 129)] do
      assert {:error, :invalid_payload} =
               AgentManage.update_runtime(host.id, %{"agent_version" => invalid_version})
    end

    send(pid, :stop)

    assert eventually(fn ->
             case AgentManage.get_agent(host.id) do
               {:ok,
                %{
                  status: :offline,
                  last_heartbeat_at: %DateTime{},
                  runtime: %{agent_version: "0.3.0", capture: %{"spool_depth" => nil}}
                }} ->
                 true

               _ ->
                 false
             end
           end)
  end

  test "keeps retained capture visibly stale until a fresh capture heartbeat arrives" do
    assert {:ok, host, auth_token, _token} =
             Hosts.create_agent_with_token(%{"name" => "capture-reconnect"})

    first_channel = spawn(fn -> Process.sleep(:infinity) end)
    replacement_channel = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(first_channel, :kill)
      Process.exit(replacement_channel, :kill)
    end)

    assert :ok = AgentManage.register_connection(host, auth_token, first_channel, %{})

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "agent_version" => "0.3.0",
               "capture" => %{"connection_state" => "connected", "spool_depth" => 4}
             })

    assert {:ok, %{last_heartbeat_at: last_heartbeat_at}} = AgentManage.get_agent(host.id)
    assert :ok = AgentManage.register_connection(host, auth_token, replacement_channel, %{})

    assert {:ok,
            %{
              status: :online,
              last_heartbeat_at: ^last_heartbeat_at,
              runtime: %{capture: %{"connection_state" => "disconnected", "spool_depth" => 4}}
            }} = AgentManage.get_agent(host.id)

    assert :ok = AgentManage.update_runtime(host.id, %{"agent_version" => "0.2.0"})
    assert {:ok, %{runtime: runtime}} = AgentManage.get_agent(host.id)
    refute Map.has_key?(runtime, :capture)
  end

  test "plugin actions run through the connected host-agent channel" do
    Application.put_env(:backplane_skills, :host_agent_channel_push_module, FakePluginPush)
    Application.put_env(:backplane_skills, :host_agent_plugin_call_timeout, 250)

    assert {:ok, host, auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "t430"})
    assert :ok = AgentManage.register_connection(host, auth_token, self(), %{})
    assert {:ok, entry} = AgentManage.get_agent(host.id)

    task =
      Task.async(fn ->
        AgentPlugins.install(entry, %{
          "plugin" => "memory",
          "runtime" => "hermes",
          "force" => "true"
        })
      end)

    assert_receive {:agent_push, "plugin_call",
                    %{
                      "call_id" => call_id,
                      "name" => "host_agent::install_plugin",
                      "arguments" => %{
                        "plugin" => "memory",
                        "runtime" => "hermes",
                        "force" => true
                      }
                    }}

    status = %{"plugin" => "memory", "runtime" => "hermes", "installed" => true}

    assert :ok =
             AgentManage.complete_plugin_call(host.id, call_id, %{
               "ok" => true,
               "result" => status
             })

    assert {:ok, ^status} = Task.await(task)
  end

  test "refreshes cached token hashes when agent tokens change" do
    assert {:ok, host, first_token, first_plaintext} =
             Hosts.create_agent_with_token(%{"name" => "t430"})

    assert {:ok, second_token, second_plaintext} =
             Hosts.create_auth_token_for_agent(host, %{"name" => "backup"})

    assert {:ok, _host, authed_first} = AgentManage.authenticate(host.id, first_plaintext)
    assert {:ok, _host, authed_second} = AgentManage.authenticate(host.id, second_plaintext)
    assert authed_first.id == first_token.id
    assert authed_second.id == second_token.id
  end

  test "serves assigned skill archive bundles over manager chunks", %{tmp_dir: tmp_dir} do
    archive_path =
      create_archive!(
        tmp_dir,
        [
          {"repo-review/SKILL.md", skill_md(name: "Repo Review")},
          {"repo-review/meta.json", Jason.encode!(%{"slug" => "repo-review"})}
        ],
        name: "repo-review.tar.gz"
      )

    assert {:ok, skill} = Skills.ingest_archive(archive_path, [])
    assert {:ok, host, _auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "t430"})
    assert {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})

    assert {:ok, first_chunk} = AgentManage.skill_bundle_chunk(host.id, "repo-review", 0, 16)
    assert first_chunk["slug"] == "repo-review"
    assert first_chunk["checksum"] == skill.content_hash
    assert first_chunk["chunk_index"] == 0
    assert first_chunk["chunk_count"] > 1
    assert first_chunk["encoding"] == "base64"

    decoded =
      0..(first_chunk["chunk_count"] - 1)
      |> Enum.map(fn chunk_index ->
        assert {:ok, chunk} = AgentManage.skill_bundle_chunk(host.id, skill.id, chunk_index, 16)
        Base.decode64!(chunk["data"])
      end)
      |> IO.iodata_to_binary()

    assert decoded == File.read!(archive_path)
    assert {:error, :chunk_not_found} = AgentManage.skill_bundle_chunk(host.id, skill.id, 999, 16)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_env(key, nil), do: Application.delete_env(:backplane_skills, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_skills, key, value)
end
