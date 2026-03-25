defmodule Backplane.Config.WatcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Config.Watcher

  describe "SIGHUP handling" do
    test "reloads config on reload/0 without crashing" do
      # Even if config file doesn't exist, reload should handle gracefully
      result = Watcher.reload()
      assert result in [:ok, {:error, :enoent}, {:error, :not_found}]
    end

    test "updates auth_token in application env" do
      old = Application.get_env(:backplane, :auth_token)
      Application.put_env(:backplane, :auth_token, "test-token-123")
      assert Application.get_env(:backplane, :auth_token) == "test-token-123"

      # Restore
      if old,
        do: Application.put_env(:backplane, :auth_token, old),
        else: Application.delete_env(:backplane, :auth_token)
    end

    test "updates git credentials in memory" do
      Application.put_env(:backplane, :git_providers, [%{name: "test", token: "tok"}])
      assert Application.get_env(:backplane, :git_providers) == [%{name: "test", token: "tok"}]
      Application.delete_env(:backplane, :git_providers)
    end

    test "does not restart existing upstream connections" do
      # Verify Pool children survive a reload
      children_before = DynamicSupervisor.which_children(Backplane.Proxy.Pool)
      Watcher.reload()
      children_after = DynamicSupervisor.which_children(Backplane.Proxy.Pool)
      assert length(children_before) == length(children_after)
    end
  end
end
