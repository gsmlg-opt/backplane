defmodule Backplane.ClientsTest do
  use Backplane.DataCase, async: false

  import Backplane.Fixtures

  alias Backplane.Clients

  describe "verify_token/1" do
    test "returns {:ok, client} for valid token" do
      {client, token} = insert_client(token: "my-secret-token")

      assert {:ok, verified} = Clients.verify_token(token)
      assert verified.id == client.id
    end

    test "returns :error for invalid token" do
      insert_client(token: "my-secret-token")

      assert :error = Clients.verify_token("wrong-token")
    end

    test "returns :error for inactive client token" do
      {_client, token} = insert_client(active: false, token: "inactive-token")

      assert :error = Clients.verify_token(token)
    end

    test "refresh_cache marks inactive-only client rows as configured" do
      old_flag = :persistent_term.get(:backplane_clients_exist, false)
      on_exit(fn -> :persistent_term.put(:backplane_clients_exist, old_flag) end)

      {_client, token} = insert_client(active: false, token: "inactive-token")
      :persistent_term.put(:backplane_clients_exist, false)

      assert :ok = Clients.refresh_cache()
      assert :persistent_term.get(:backplane_clients_exist) == true
      assert :error = Clients.verify_token(token)
    end

    test "refresh_cache preserves the last known state when the database query fails" do
      old_flag = :persistent_term.get(:backplane_clients_exist, false)
      {client, _token} = insert_client(token: "cached-token")
      assert :ok = Clients.refresh_cache()

      on_exit(fn ->
        :persistent_term.put(:backplane_clients_exist, old_flag)
        :ets.delete(:backplane_clients_cache, client.id)
      end)

      assert [{client_id, _cached}] = :ets.lookup(:backplane_clients_cache, client.id)
      assert client_id == client.id
      assert :persistent_term.get(:backplane_clients_exist) == true

      Ecto.Adapters.SQL.query!(Backplane.Repo, "SET LOCAL search_path TO pg_catalog")

      assert :ok = Clients.refresh_cache()
      assert [{^client_id, _cached}] = :ets.lookup(:backplane_clients_cache, client.id)
      assert :persistent_term.get(:backplane_clients_exist) == true
    end

    test "refresh_cache fails closed without a protected last-known state" do
      old_flag = :persistent_term.get(:backplane_clients_exist, :missing)

      on_exit(fn ->
        case old_flag do
          :missing -> :persistent_term.erase(:backplane_clients_exist)
          value -> :persistent_term.put(:backplane_clients_exist, value)
        end
      end)

      :persistent_term.put(:backplane_clients_exist, false)
      Ecto.Adapters.SQL.query!(Backplane.Repo, "SET LOCAL search_path TO pg_catalog")

      assert :ok = Clients.refresh_cache()
      assert :persistent_term.get(:backplane_clients_exist) == true
    end

    test "concurrent refreshes cannot publish an older client snapshot last" do
      old_flag = :persistent_term.get(:backplane_clients_exist, false)
      {client, _token} = insert_client(token: "racing-token")
      assert :ok = Clients.refresh_cache()

      handler_id = "clients-refresh-race-#{System.unique_integer([:positive])}"
      parent = self()
      {:ok, gate} = Agent.start_link(fn -> false end)

      first_refresh =
        Task.async(fn ->
          receive do
            :start_refresh -> Clients.refresh_cache()
          end
        end)

      :ok =
        :telemetry.attach(
          handler_id,
          [:backplane, :repo, :query],
          fn _event, _measurements, metadata, {target, test_pid, gate} ->
            first_client_query? =
              self() == target and
                metadata[:source] == "clients" and
                Agent.get_and_update(gate, fn
                  false -> {true, true}
                  true -> {false, true}
                end)

            if first_client_query? do
              send(test_pid, :older_snapshot_loaded)

              receive do
                :publish_older_snapshot -> :ok
              end
            end
          end,
          {first_refresh.pid, parent, gate}
        )

      on_exit(fn ->
        send(first_refresh.pid, :publish_older_snapshot)
        :telemetry.detach(handler_id)
        :persistent_term.put(:backplane_clients_exist, old_flag)
        :ets.delete(:backplane_clients_cache, client.id)
      end)

      send(first_refresh.pid, :start_refresh)
      assert_receive :older_snapshot_loaded, 1_000
      Backplane.Repo.delete!(client)

      second_refresh =
        Task.async(fn ->
          send(parent, :newer_refresh_started)
          Clients.refresh_cache()
        end)

      assert_receive :newer_refresh_started, 1_000
      second_result = Task.yield(second_refresh, 500)

      send(first_refresh.pid, :publish_older_snapshot)
      assert Task.await(first_refresh, 1_000) == :ok

      case second_result do
        {:ok, :ok} -> :ok
        nil -> assert Task.await(second_refresh, 1_000) == :ok
      end

      assert :ets.lookup(:backplane_clients_cache, client.id) == []
      assert :persistent_term.get(:backplane_clients_exist) == false
    end

    test "updates last_seen_at on successful verify" do
      {client, token} = insert_client(token: "my-secret-token")
      assert is_nil(client.last_seen_at)

      assert {:ok, _verified} = Clients.verify_token(token)

      Process.sleep(100)

      reloaded = Backplane.Repo.get!(Backplane.Clients.Client, client.id)
      assert reloaded.last_seen_at != nil
    end
  end

  describe "scope_matches?/2" do
    test ~s("*" matches any tool name) do
      assert Clients.scope_matches?(["*"], "docs::query-docs")
    end

    test ~s("docs::*" matches "docs::query-docs") do
      assert Clients.scope_matches?(["docs::*"], "docs::query-docs")
    end

    test ~s("docs::*" does not match "git::repo-tree") do
      refute Clients.scope_matches?(["docs::*"], "git::repo-tree")
    end

    test ~s("docs::query-docs" matches exactly) do
      assert Clients.scope_matches?(["docs::query-docs"], "docs::query-docs")
    end

    test ~s("docs::query-docs" does not match "docs::resolve-project") do
      refute Clients.scope_matches?(["docs::query-docs"], "docs::resolve-project")
    end

    test "multiple scopes: match if any scope matches" do
      scopes = ["docs::*", "git::repo-tree"]

      assert Clients.scope_matches?(scopes, "docs::query-docs")
      assert Clients.scope_matches?(scopes, "git::repo-tree")
      refute Clients.scope_matches?(scopes, "git::list-repos")
    end

    test "canonical memory permissions match only their operation class" do
      assert Clients.scope_matches?(["memory.read"], "memory::recall")
      assert Clients.scope_matches?(["memory.write"], "memory::remember")
      assert Clients.scope_matches?(["memory.write"], "memory::apply")
      assert Clients.scope_matches?(["memory.coordinate"], "memory::action_create")
      assert Clients.scope_matches?(["memory.replay"], "memory::export")
      assert Clients.scope_matches?(["memory.admin"], "memory::governance_delete")

      refute Clients.scope_matches?(["memory.read"], "memory::remember")
      refute Clients.scope_matches?(["memory.read"], "memory::apply")
      refute Clients.scope_matches?(["memory.write"], "memory::recall")
      refute Clients.scope_matches?(["memory.coordinate"], "memory::export")
      refute Clients.scope_matches?(["memory.replay"], "memory::audit")
      refute Clients.scope_matches?(["memory.admin"], "docs::query-docs")
    end

    test "host-agent permissions are exact and independently assignable" do
      for permission <- ~w(host_agent.capture host_agent.recall host_agent.import) do
        assert Clients.scope_matches?([permission], permission)

        assert {:ok, _client} =
                 Clients.create_client(%{
                   name: "#{permission}-#{System.unique_integer([:positive])}",
                   token: "token",
                   scopes: [permission]
                 })
      end

      refute Clients.scope_matches?(["host_agent.capture"], "host_agent.recall")
      refute Clients.scope_matches?(["host_agent.recall"], "host_agent.import")
      refute Clients.scope_matches?(["host_agent.import"], "host_agent.capture")
    end

    test "every canonical memory tool has exactly one permission class" do
      permissions = Backplane.MemoryPermissions.tool_permissions()

      assert map_size(permissions) == 55
      assert permissions["memory::apply"] == "memory.write"
      assert permissions["memory::lesson_save"] == "memory.write"
      assert permissions["memory::lesson_recall"] == "memory.read"
      assert permissions["memory::crystallize"] == "memory.admin"
      assert permissions["memory::crystal_get"] == "memory.read"
      assert permissions["memory::activity_summary"] == "memory.read"
      assert permissions["memory::recall_explain"] == "memory.read"
      assert permissions["memory::replay_load"] == "memory.replay"
      assert permissions["memory::replay_import"] == "memory.admin"

      assert Enum.all?(permissions, fn {name, permission} ->
               String.starts_with?(name, "memory::") and
                 permission in ~w(memory.read memory.write memory.coordinate memory.replay memory.admin)
             end)
    end
  end

  describe "upsert_from_config/1" do
    test "creates new client from config" do
      assert {:ok, client} =
               Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["*"]})

      assert client.name == "test"
      assert client.scopes == ["*"]
    end

    test "updates existing client scopes on re-boot" do
      {:ok, original} =
        Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["*"]})

      {:ok, updated} =
        Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["docs::*"]})

      assert updated.id == original.id
      assert updated.scopes == ["docs::*"]
    end
  end
end
