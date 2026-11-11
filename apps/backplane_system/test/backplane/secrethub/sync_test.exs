defmodule Backplane.SecretHub.SyncTest do
  use BackplaneSystem.DataCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.SecretHub.{FakeAgent, Publication, Sync, SyncWorker}
  alias Backplane.Settings.Credentials

  setup do
    socket = Path.join(System.tmp_dir!(), "bp-sh-#{System.unique_integer([:positive])}.sock")
    agent = start_supervised!({FakeAgent, path: socket, owner: self()})

    previous =
      for key <- [Sync.enabled_key(), Sync.socket_key()],
          do: {key, :ets.lookup(:backplane_settings, key)}

    :ets.insert(:backplane_settings, {Sync.enabled_key(), true})
    :ets.insert(:backplane_settings, {Sync.socket_key(), socket})

    on_exit(fn ->
      for {key, entries} <- previous do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, entries)
      end
    end)

    %{agent: agent}
  end

  test "API keys are published under backplane.<kind>.<name>; others are not", ctx do
    {:ok, _} = Credentials.store("OpenAI_Main", "sk-canary-1", "llm")

    {:ok, _} =
      Credentials.store("oauth-thing", ~s({"access_token":"x"}), "llm", %{
        "auth_type" => "anthropic_oauth"
      })

    assert {:ok, %{synced: 2, failed: 0}} = Sync.reconcile()

    assert %{"backplane.llm.openai-main" => %{data: %{"api_key" => "sk-canary-1"}, version: 1}} =
             FakeAgent.secrets(ctx.agent)

    assert map_size(FakeAgent.secrets(ctx.agent)) == 1

    assert %Publication{path: "backplane.llm.openai-main", version: 1, last_error: nil} =
             Repo.get(Publication, "OpenAI_Main")

    # Reconciling again republishes the same value without a new version.
    assert {:ok, _} = Sync.reconcile()
    assert %{version: 1} = FakeAgent.secrets(ctx.agent)["backplane.llm.openai-main"]
  end

  test "an unavailable Agent never affects local storage and is repaired later", ctx do
    :ok = FakeAgent.set_available(ctx.agent, false)

    log =
      capture_log(fn ->
        assert {:ok, _} = Credentials.store("svc-key", "sk-canary-2", "service")
        assert {:error, :agent_unavailable} = Sync.sync_credential("svc-key")
        assert {:error, :agent_unavailable} = Sync.reconcile()
      end)

    assert {:ok, "sk-canary-2"} = Credentials.fetch("svc-key")

    assert %Publication{last_error: "agent_unavailable", version: nil} =
             Repo.get(Publication, "svc-key")

    assert %{failing: 1, published: 0} = Sync.status()
    refute log =~ "sk-canary-2"

    :ok = FakeAgent.set_available(ctx.agent, true)
    assert {:ok, %{failed: 0}} = Sync.reconcile()

    assert %{"backplane.service.svc-key" => %{data: %{"api_key" => "sk-canary-2"}}} =
             FakeAgent.secrets(ctx.agent)

    assert %{failing: 0, published: 1} = Sync.status()
  end

  test "rotation, kind changes and deletion keep SecretHub in line", ctx do
    {:ok, _} = Credentials.store("key", "v1", "llm")
    assert :ok = Sync.sync_credential("key")

    {:ok, _} = Credentials.rotate("key", "v2")
    assert :ok = Sync.sync_credential("key")

    assert %{data: %{"api_key" => "v2"}, version: 2} =
             FakeAgent.secrets(ctx.agent)["backplane.llm.key"]

    # A kind change moves the secret: the old path is removed first.
    {:ok, _} = Credentials.update("key", %{kind: "service"})
    assert :ok = Sync.sync_credential("key")
    assert Map.keys(FakeAgent.secrets(ctx.agent)) == ["backplane.service.key"]
    assert %Publication{path: "backplane.service.key"} = Repo.get(Publication, "key")

    # Becoming an OAuth credential or being deleted withdraws the publication.
    :ok = Credentials.delete("key")
    assert :ok = Sync.sync_credential("key")
    assert FakeAgent.secrets(ctx.agent) == %{}
    assert Repo.get(Publication, "key") == nil
  end

  test "names that normalize to the same path never overwrite each other", ctx do
    {:ok, _} = Credentials.store("My_Key", "first", "llm")
    {:ok, _} = Credentials.store("my-key", "second", "llm")

    assert :ok = Sync.sync_credential("My_Key")
    capture_log(fn -> assert {:error, :path_collision} = Sync.sync_credential("my-key") end)

    assert %{"backplane.llm.my-key" => %{data: %{"api_key" => "first"}}} =
             FakeAgent.secrets(ctx.agent)

    refute_received {:secrethub_request, "secret_put", %{"data" => %{"api_key" => "second"}}}
  end

  test "the worker is a no-op while sync is disabled", ctx do
    :ets.insert(:backplane_settings, {Sync.enabled_key(), false})
    {:ok, _} = Credentials.store("idle", "v", "llm")

    assert :ok = SyncWorker.perform(%Styx.Job{args: %{}})
    assert :ok = SyncWorker.perform(%Styx.Job{args: %{"credential_name" => "idle"}})
    assert FakeAgent.secrets(ctx.agent) == %{}
    refute_received {:secrethub_request, _, _}
  end

  test "the worker retries transient failures and cancels permanent ones", ctx do
    {:ok, _} = Credentials.store("worker-key", "v", "llm")
    :ok = FakeAgent.set_available(ctx.agent, false)

    capture_log(fn ->
      assert {:error, :agent_unavailable} =
               SyncWorker.perform(%Styx.Job{args: %{"credential_name" => "worker-key"}})

      # A full reconciliation defers quietly; cron runs it again.
      assert :ok = SyncWorker.perform(%Styx.Job{args: %{}})
    end)

    :ok = FakeAgent.set_available(ctx.agent, true)
    assert :ok = SyncWorker.perform(%Styx.Job{args: %{"credential_name" => "worker-key"}})

    {:ok, _} = Credentials.store("worker_key", "other", "llm")

    capture_log(fn ->
      assert {:cancel, :path_collision} =
               SyncWorker.perform(%Styx.Job{args: %{"credential_name" => "worker_key"}})
    end)
  end
end
