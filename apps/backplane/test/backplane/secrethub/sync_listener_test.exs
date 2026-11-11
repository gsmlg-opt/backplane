defmodule Backplane.SecretHub.SyncListenerTest do
  use Backplane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.SecretHub.{Publication, Sync}
  alias Backplane.Settings.Credentials

  setup do
    keys = [Sync.enabled_key(), Sync.socket_key()]
    previous = for key <- keys, do: {key, :ets.lookup(:backplane_settings, key)}

    # No Agent listens here: every sync attempt records agent_unavailable.
    :ets.insert(:backplane_settings, {Sync.socket_key(), "/nonexistent/secrethub-agent.sock"})

    on_exit(fn ->
      for {key, entries} <- previous do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, entries)
      end
    end)

    :ok
  end

  test "a credential change runs a sync job while local storage succeeds" do
    :ets.insert(:backplane_settings, {Sync.enabled_key(), true})

    capture_log(fn ->
      assert {:ok, _} = Credentials.store("listener-key", "sk-listener", "llm")
      assert %Publication{last_error: "agent_unavailable"} = await_publication("listener-key")
    end)

    assert {:ok, "sk-listener"} = Credentials.fetch("listener-key")
  end

  test "nothing runs while sync is off" do
    :ets.insert(:backplane_settings, {Sync.enabled_key(), false})
    {:ok, _} = Credentials.store("quiet-key", "sk-quiet", "llm")
    Process.sleep(300)
    assert Repo.get(Publication, "quiet-key") == nil
  end

  # The listener reacts asynchronously to the broadcast.
  defp await_publication(name, attempts \\ 100) do
    case Repo.get(Publication, name) do
      %Publication{} = publication ->
        publication

      nil when attempts > 0 ->
        Process.sleep(20)
        await_publication(name, attempts - 1)

      nil ->
        flunk("no sync attempt recorded for #{name}")
    end
  end
end
