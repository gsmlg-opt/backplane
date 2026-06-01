defmodule Backplane.HostAgent.WorkerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.{Manifest, Worker}

  defmodule FakeChannel do
    def push(_channel, event, payload) do
      owner = Process.get(:test_owner) || :persistent_term.get({__MODULE__, :owner}, self())
      send(owner, {:push, event, payload})

      case Process.get({__MODULE__, event}) do
        nil -> {:ok, %{"ok" => true}}
        reply -> reply
      end
    end
  end

  defmodule ExitingChannel do
    def push(_channel, event, payload) do
      owner = Process.get(:test_owner) || :persistent_term.get({__MODULE__, :owner}, self())
      send(owner, {:push, event, payload})
      exit(:shutdown)
    end
  end

  defmodule FakeMcpManager do
    def reconcile(servers) do
      owner = Process.get(:test_owner) || :persistent_term.get({__MODULE__, :owner}, self())
      send(owner, {:reconcile_mcp_servers, servers})
      :ok
    end
  end

  defmodule FakeInstaller do
    def install(skill, config) do
      send(self(), {:install, skill, config})
      Process.get(__MODULE__, {:ok, ["agents"]})
    end

    def remove(skill, config) do
      send(self(), {:remove, skill, config})
      Process.get({__MODULE__, :remove}, {:ok, ["agents"]})
    end
  end

  defmodule FakeRuntimeConfig do
    def load_default do
      {:ok,
       %{
         host_id: "host-1",
         hub_url: "http://localhost:4220",
         machine_name: "t430",
         manifest_path: "/tmp/manifest.json",
         token: "host-token"
       }}
    end
  end

  defmodule FakeConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})
      {:ok, %{channel: self(), host_id: "host-1", host_name: "t430", socket: self()}}
    end
  end

  defmodule FakeMemoryProxy do
    def set_channel(channel) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:set_channel, channel})
      :ok
    end
  end

  defmodule FakeHttpServer do
    def child_spec(_config), do: nil
  end

  test "status returns last sync state" do
    {:ok, pid} = Worker.start_link(name: nil, connect?: false)

    assert %{last_sync: nil, last_error: nil} = GenServer.call(pid, :status)
  end

  test "loads config and connects when started by the release supervisor" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    assert_receive {:connect, %{host_id: "host-1", machine_name: "t430", token: "host-token"}}
    assert_receive {:set_channel, ^pid}

    assert %{channel: ^pid, config: %{machine_name: "t430"}, last_error: nil} =
             GenServer.call(pid, :status)
  end

  @tag :tmp_dir
  test "schedules an immediate sync after startup", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    :persistent_term.put({FakeChannel, :owner}, self())
    :persistent_term.put({FakeMcpManager, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeChannel, :owner})
      :persistent_term.erase({FakeMcpManager, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        connect?: false,
        channel: self(),
        channel_module: FakeChannel,
        config: Map.put(config, :interval_ms, 60_000),
        desired: %{"skills" => []},
        installer_module: FakeInstaller,
        mcp_manager_module: FakeMcpManager
      )

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:reconcile_mcp_servers, []}
    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => []}}

    assert %{last_sync: %DateTime{}, last_error: nil, sync_timer_ref: timer_ref} =
             GenServer.call(pid, :status)

    assert is_reference(timer_ref)
  end

  @tag :tmp_dir
  test "run_once uses injected desired state and installs planned skills", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "version" => "1.0.0",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    state = state(config, desired: desired)

    assert {:ok, updated} = Worker.run_once(state)
    assert %{last_sync: %DateTime{}, last_error: nil} = updated

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    refute_received {:push, "get_desired", %{}}

    assert_receive {:install, desired_skill, install_config}
    assert desired_skill["slug"] == "repo-review"
    assert_install_config(install_config, config)

    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => [result]}}

    assert %{
             "skill_name" => "Repo Review",
             "skill_slug" => "repo-review",
             "status" => "installed",
             "checksum" => "sha256:a",
             "targets" => ["agents"]
           } = result

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)

    assert [
             %{
               checksum: "sha256:a",
               name: "Repo Review",
               owned: true,
               slug: "repo-review",
               targets: ["agents"],
               version: "1.0.0"
             }
           ] = manifest.skills

    assert {:ok, _updated_again} = Worker.run_once(state)

    refute_received {:install, _skill, _config}
    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => [noop_result]}}
    assert %{"skill_slug" => "repo-review", "status" => "noop"} = noop_result
  end

  @tag :tmp_dir
  test "run_once fetches desired state when not injected", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    Process.put({FakeChannel, "get_desired"}, {:ok, desired})

    assert {:ok, _updated} = Worker.run_once(state(config))

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "get_desired", %{}}
    assert_receive {:install, desired_skill, install_config}
    assert desired_skill["slug"] == "repo-review"
    assert_install_config(install_config, config)
    assert_receive {:push, "sync_result", %{"status" => "synced"}}
  end

  @tag :tmp_dir
  test "run_once does not update manifest when sync_result reporting fails", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put({FakeChannel, "sync_result"}, {:error, :socket_down})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:error, :socket_down, updated} = Worker.run_once(state(config, desired: desired))
    assert updated.last_error == :socket_down

    assert_receive {:install, _desired_skill, install_config}
    assert_install_config(install_config, config)
    assert_receive {:push, "sync_result", %{"status" => "synced"}}

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert manifest.skills == []
  end

  @tag :tmp_dir
  test "run_once records channel exits instead of crashing", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    assert {:error, {:channel_exit, :shutdown}, updated} =
             Worker.run_once(%{state(config) | channel_module: ExitingChannel})

    assert updated.last_error == {:channel_exit, :shutdown}
    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
  end

  @tag :tmp_dir
  test "run_once stores the targets actually installed in the manifest", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put(FakeInstaller, {:ok, ["agents"]})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents", "commands"]
        }
      ]
    }

    assert {:ok, _updated} = Worker.run_once(state(config, desired: desired))

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{slug: "repo-review", targets: ["agents"]}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once records manifest read errors instead of crashing", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    File.write!(config.manifest_path, "{not-json")

    assert {:error, {:manifest_read_error, _message}, updated} =
             Worker.run_once(state(config, desired: %{"skills" => []}))

    assert {:manifest_read_error, _message} = updated.last_error
  end

  @tag :tmp_dir
  test "run_once records valid JSON manifest shape errors instead of crashing", %{
    tmp_dir: tmp_dir
  } do
    config = config(tmp_dir)
    File.write!(config.manifest_path, "[]")

    assert {:error, {:manifest_read_error, _message}, updated} =
             Worker.run_once(state(config, desired: %{"skills" => []}))

    assert {:manifest_read_error, _message} = updated.last_error
  end

  @tag :tmp_dir
  test "run_once records non-object manifest JSON errors instead of crashing", %{tmp_dir: tmp_dir} do
    for json <- ["null", "1", "\"value\"", "true"] do
      config = config(Path.join(tmp_dir, Base.encode16(json)))
      File.mkdir_p!(Path.dirname(config.manifest_path))
      File.write!(config.manifest_path, json)

      assert {:error, {:manifest_read_error, _message}, updated} =
               Worker.run_once(state(config, desired: %{"skills" => []}))

      assert {:manifest_read_error, _message} = updated.last_error
    end
  end

  @tag :tmp_dir
  test "run_once returns noop and removes manifest-owned stale skills", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    write_manifest(config.manifest_path, [
      %{name: "Manual", slug: "manual", checksum: "sha256:m", targets: ["agents"], owned: false},
      %{
        name: "Old Skill",
        slug: "old-skill",
        checksum: "sha256:o",
        targets: ["agents"],
        owned: true
      }
    ])

    desired = %{
      "skills" => [
        %{
          "name" => "Manual",
          "slug" => "manual",
          "checksum" => "sha256:m",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:ok, _updated} = Worker.run_once(state(config, desired: desired))

    refute_received {:install, _skill, _config}
    assert_receive {:remove, removed_skill, ^config}
    assert removed_skill.slug == "old-skill"

    assert_receive {:push, "sync_result", %{"results" => results}}

    assert [
             %{"skill_slug" => "manual", "status" => "noop"},
             %{"skill_slug" => "old-skill", "status" => "removed"}
           ] = results

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{owned: false, slug: "manual"}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once retains manifest targets not removed by a partial remove", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put({FakeInstaller, :remove}, {:ok, ["agents"]})

    write_manifest(config.manifest_path, [
      %{
        name: "Old Skill",
        slug: "old-skill",
        checksum: "sha256:o",
        targets: ["agents", "commands"],
        owned: true
      }
    ])

    assert {:ok, _updated} = Worker.run_once(state(config, desired: %{"skills" => []}))

    assert_receive {:remove, removed_skill, ^config}
    assert removed_skill.slug == "old-skill"
    assert_receive {:push, "sync_result", %{"results" => [%{"targets" => ["agents"]}]}}

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{owned: true, slug: "old-skill", targets: ["commands"]}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once marks installer failures and records last_error", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put(FakeInstaller, {:error, :download_missing})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:error, "download_missing", updated} =
             Worker.run_once(state(config, desired: desired))

    assert updated.last_sync == nil
    assert updated.last_error == "download_missing"

    assert_receive {:push, "sync_result", %{"status" => "failed", "results" => [result]}}

    assert %{"skill_slug" => "repo-review", "status" => "failed", "error" => "download_missing"} =
             result
  end

  defp state(config, opts \\ []) do
    %{
      channel: self(),
      channel_module: FakeChannel,
      config: config,
      desired: Keyword.get(opts, :desired),
      installer_module: FakeInstaller,
      last_error: nil,
      last_sync: nil,
      mcp_manager_module: FakeMcpManager
    }
  end

  defp config(tmp_dir) do
    %{
      host_id: "host-1",
      machine_name: "t430",
      manifest_path: Path.join(tmp_dir, "manifest.json"),
      targets: [%{name: "agents", runtime: "agent-skills", path: tmp_dir, enabled: true}]
    }
  end

  defp write_manifest(path, skills) do
    File.write!(path, Jason.encode!(%{schema_version: 1, machine_name: "t430", skills: skills}))
  end

  defp assert_install_config(install_config, config) do
    assert install_config.machine_name == config.machine_name
    assert install_config.manifest_path == config.manifest_path
    assert install_config.targets == config.targets
    assert install_config.channel == self()
    assert install_config.channel_module == FakeChannel
  end
end
