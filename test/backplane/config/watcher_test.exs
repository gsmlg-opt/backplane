defmodule Backplane.Config.WatcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Config.Watcher
  alias Backplane.Proxy.Pool

  @test_toml_dir "/tmp/backplane_watcher_test_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_toml_dir)
    on_exit(fn -> File.rm_rf!(@test_toml_dir) end)
    :ok
  end

  describe "reload/0" do
    test "returns {:error, :not_found} when config file does not exist" do
      old_path = Application.get_env(:backplane, :config_path)
      Application.put_env(:backplane, :config_path, "/tmp/nonexistent_backplane_toml.toml")

      assert {:error, :not_found} = Watcher.reload()

      if old_path,
        do: Application.put_env(:backplane, :config_path, old_path),
        else: Application.delete_env(:backplane, :config_path)
    end

    test "returns :ok and applies config when valid TOML exists" do
      toml_path = Path.join(@test_toml_dir, "backplane.toml")

      File.write!(toml_path, """
      [backplane]
      auth_token = "test-reload-token"
      """)

      old_path = Application.get_env(:backplane, :config_path)
      old_token = Application.get_env(:backplane, :auth_token)
      Application.put_env(:backplane, :config_path, toml_path)

      assert :ok = Watcher.reload()
      assert Application.get_env(:backplane, :auth_token) == "test-reload-token"

      # Restore
      if old_path,
        do: Application.put_env(:backplane, :config_path, old_path),
        else: Application.delete_env(:backplane, :config_path)

      if old_token,
        do: Application.put_env(:backplane, :auth_token, old_token),
        else: Application.delete_env(:backplane, :auth_token)
    end

    test "returns {:error, :reload_failed} for invalid TOML" do
      toml_path = Path.join(@test_toml_dir, "bad.toml")
      File.write!(toml_path, "{{{{invalid toml}}}}")

      old_path = Application.get_env(:backplane, :config_path)
      Application.put_env(:backplane, :config_path, toml_path)

      assert {:error, :reload_failed} = Watcher.reload()

      if old_path,
        do: Application.put_env(:backplane, :config_path, old_path),
        else: Application.delete_env(:backplane, :config_path)
    end

    test "applies github providers from config" do
      toml_path = Path.join(@test_toml_dir, "github.toml")

      File.write!(toml_path, """
      [github.personal]
      token = "gh-test-token"
      """)

      old_path = Application.get_env(:backplane, :config_path)
      old_github = Application.get_env(:backplane, :github_providers)
      Application.put_env(:backplane, :config_path, toml_path)

      assert :ok = Watcher.reload()
      assert Application.get_env(:backplane, :github_providers) != nil

      if old_path,
        do: Application.put_env(:backplane, :config_path, old_path),
        else: Application.delete_env(:backplane, :config_path)

      if old_github,
        do: Application.put_env(:backplane, :github_providers, old_github),
        else: Application.delete_env(:backplane, :github_providers)
    end

    test "reconciles upstreams — unchanged config keeps existing connections" do
      children_before = DynamicSupervisor.which_children(Pool)
      Watcher.reload()
      children_after = DynamicSupervisor.which_children(Pool)
      assert length(children_before) == length(children_after)
    end

    test "reconciles upstreams — removes upstream not in config" do
      # Start a test upstream manually on a random port
      {:ok, bandit} =
        Bandit.start_link(
          plug: Backplane.Test.MockMcpPlug,
          port: 0,
          ip: {127, 0, 0, 1}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

      on_exit(fn ->
        if Process.alive?(bandit) do
          try do
            GenServer.stop(bandit)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      config = %{
        name: "watcher-reconcile-test",
        prefix: "watcher_test",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{}
      }

      {:ok, _pid} = Pool.start_upstream(config)
      Process.sleep(300)

      # Verify it's running
      upstreams_before = Pool.list_upstreams()
      assert Enum.any?(upstreams_before, fn u -> u.prefix == "watcher_test" end)

      # Reload with a config that has no upstreams — should remove the one we added
      toml_path = Path.join(@test_toml_dir, "no_upstreams.toml")

      File.write!(toml_path, """
      [backplane]
      auth_token = "test-token"
      """)

      old_path = Application.get_env(:backplane, :config_path)
      Application.put_env(:backplane, :config_path, toml_path)

      Watcher.reload()
      Process.sleep(200)

      # The watcher_test prefix upstream should be gone
      upstreams_after = Pool.list_upstreams()
      refute Enum.any?(upstreams_after, fn u -> u.prefix == "watcher_test" end)

      if old_path,
        do: Application.put_env(:backplane, :config_path, old_path),
        else: Application.delete_env(:backplane, :config_path)

      # Watcher.reload() applied auth_token from the TOML — clean it up
      Application.delete_env(:backplane, :auth_token)
    end
  end

  describe "GenServer" do
    test "handles SIGHUP signal message without crashing" do
      pid = Process.whereis(Watcher)

      if pid do
        send(pid, {:signal, :sighup})
        Process.sleep(50)
        assert Process.alive?(pid)
      end
    end

    test "handles unknown messages gracefully" do
      pid = Process.whereis(Watcher)

      if pid do
        send(pid, :unknown_message)
        Process.sleep(10)
        assert Process.alive?(pid)
      end
    end
  end
end
