defmodule Backplane.ClientsTest do
  use BackplaneSystem.DataCase, async: false

  import BackplaneSystem.Fixtures

  alias Backplane.Clients

  test "client presence distinguishes authoritative empty and inactive unissued rows" do
    assert {:ok, false} = Clients.fetch_any_clients()
    refute Clients.any_clients?()

    assert {:ok, client} =
             Clients.create_client(%{
               name: "inactive-unissued-presence",
               scopes: ["*"],
               active: false
             })

    assert is_nil(client.token_digest)
    assert {:ok, true} = Clients.fetch_any_clients()
    assert Clients.any_clients?()

    assert {:ok, _} = Clients.delete_client(client)
    assert {:ok, false} = Clients.fetch_any_clients()
    refute Clients.any_clients?()
  end

  test "client presence reports unavailable when the sandbox database query fails" do
    Ecto.Adapters.SQL.query!(Repo, "SET LOCAL search_path TO pg_catalog")

    assert {:error, :unavailable} = Clients.fetch_any_clients()
    assert Clients.any_clients?()
  end

  test "trusted issuance uses indexed credentials and rotation revokes its predecessor" do
    assert {:ok, client, token} = Clients.issue_client(%{name: "indexed", scopes: ["*"]})
    assert byte_size(token) == 47
    assert String.starts_with?(token, "bp2_")
    assert Map.fetch!(client, :token_digest) == :crypto.hash(:sha256, token)
    assert :ok = Clients.refresh_cache()
    assert {:ok, verified} = Backplane.Clients.AuthCache.verify(token)
    assert verified.id == client.id
    assert {:ok, rotated, replacement} = Clients.rotate_client_token(client)
    assert :error = Backplane.Clients.AuthCache.verify(token)
    assert {:ok, verified} = Backplane.Clients.AuthCache.verify(replacement)
    assert verified.id == rotated.id
    assert {:ok, _} = Clients.revoke_client_token(rotated)
    assert :error = Backplane.Clients.AuthCache.verify(replacement)
  end

  test "credential SQL never publishes plaintext or digest through logs or telemetry" do
    parent = self()
    handler = "credential-query-secrecy-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:backplane, :repo, :query],
      fn _, _, metadata, _ ->
        send(parent, {:credential_sql_event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    logs =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:ok, client, token} = Clients.issue_client(%{name: "secret-sql", scopes: ["*"]})
        assert {:ok, _} = Clients.verify_token(token)
        assert {:error, _} = Clients.issue_client(%{name: "secret-sql", scopes: ["*"]})
        assert {:error, _} = Clients.rotate_client_token(client, %{token: "forbidden-plaintext"})
        assert [listed] = Clients.list_clients()
        assert listed.id == client.id
        assert Clients.get_client(client.id).id == client.id
        assert Clients.get_client_by_name(client.name).id == client.id
        assert {:ok, client} = Clients.update_client(client, %{scopes: ["docs::*"]})
        assert :ok = Clients.refresh_cache()
        assert {:ok, rotated, replacement} = Clients.rotate_client_token(client)
        assert {:ok, _} = Clients.verify_token(replacement)
        assert {:ok, revoked} = Clients.revoke_client_token(rotated)
        assert {:ok, _} = Clients.delete_client(revoked)

        assert {:ok, unissued} =
                 Clients.create_client(%{name: "secret-sql-unissued", scopes: ["*"]})

        assert Clients.any_clients?()
        assert {:ok, true} = Clients.fetch_any_clients()
        assert {:ok, _} = Clients.delete_client(unissued)
        Ecto.Adapters.SQL.query!(Repo, "SELECT 1 AS unrelated_sql_probe", [])

        send(
          parent,
          {:secrets,
           [token, replacement, "forbidden-plaintext", client.token_digest, rotated.token_digest]}
        )
      end)

    assert_receive {:secrets, secrets}
    for secret <- secrets, do: refute(logs =~ inspect(secret))
    assert logs =~ "unrelated_sql_probe"
    events = collect_sql_events([])
    assert Enum.any?(events, &String.contains?(&1.query, "unrelated_sql_probe"))
    refute Enum.any?(events, &(&1[:source] == "clients"))
    for event <- events, secret <- secrets, do: refute(contains_secret?(event, secret))
  end

  defp collect_sql_events(events) do
    receive do
      {:credential_sql_event, event} -> collect_sql_events([event | events])
    after
      0 -> events
    end
  end

  defp contains_secret?(value, secret) when is_map(value),
    do:
      Enum.any?(Map.to_list(value), fn {k, v} ->
        contains_secret?(k, secret) or contains_secret?(v, secret)
      end)

  defp contains_secret?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_secret?(&1, secret))

  defp contains_secret?(value, secret) when is_tuple(value),
    do: contains_secret?(Tuple.to_list(value), secret)

  defp contains_secret?(value, secret), do: value == secret

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

    test "production indexed path does no bcrypt, SQL, scans or verification tasks" do
      {client, token} = insert_client(scopes: ["docs::*"])
      assert :ok = Clients.refresh_cache()
      parent = self()
      handler = "indexed-client-sql-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:backplane, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == parent and metadata.source == "clients", do: send(parent, :client_sql)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # SQL telemetry is intentionally suppressed for client queries. Calibrate
      # the independent DBConnection call trace before checking request work.
      assert_auth_work(%{bcrypt: 0, sql: 1}, fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [], log: false, telemetry_event: nil)
      end)

      assert_auth_work(%{bcrypt: 0, sql: 0}, fn ->
        assert {:ok, verified} = Backplane.Clients.AuthCache.verify(token)
        assert verified.id == client.id

        for _ <- 1..100 do
          invalid = "bp2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          assert :error = Backplane.Clients.AuthCache.verify(invalid)
        end

        assert :error = Backplane.Clients.AuthCache.verify("old-client-token")
      end)

      refute_receive :client_sql
      assert %{digests: 1} = Backplane.Clients.AuthCache.stats()
      assert :ets.whereis(:backplane_client_auth_evidence) == :undefined
      assert :ets.whereis(:backplane_client_auth_negatives) == :undefined
      assert :ets.whereis(:backplane_client_auth_ingress) == :undefined
    end

    test "matches follow scope edits, deactivation, rotation and deletion" do
      {client, token} = insert_client(scopes: ["docs::*"])
      assert {:ok, edited} = Clients.update_client(client, %{scopes: ["git::*"]})
      assert {:ok, verified} = Clients.verify_token(token)
      assert verified.scopes == ["git::*"]
      assert {:ok, inactive} = Clients.update_client(edited, %{active: false})
      assert :error = Clients.verify_token(token)
      assert {:ok, active} = Clients.update_client(inactive, %{active: true})
      assert {:ok, rotated, replacement} = Clients.rotate_client_token(active)
      assert :error = Clients.verify_token(token)
      assert {:ok, _} = Clients.verify_token(replacement)
      assert {:ok, _} = Clients.delete_client(rotated)
      assert :error = Clients.verify_token(replacement)
    end

    test "rotation validates metadata in the same operation and never returns rejected secrets" do
      {client, token} = insert_client(scopes: ["docs::*"])
      assert {:error, rejected} = Clients.rotate_client_token(client, %{token: "do-not-retain"})
      refute inspect(rejected) =~ "do-not-retain"
      refute Map.has_key?(rejected.changes, :token_digest)
      assert {:ok, _} = Clients.verify_token(token)

      assert {:ok, rotated, replacement} =
               Clients.rotate_client_token(client, %{scopes: ["git::*"]})

      assert rotated.scopes == ["git::*"]
      assert :error = Clients.verify_token(token)
      assert {:ok, verified} = Clients.verify_token(replacement)
      assert verified.scopes == ["git::*"]
    end

    test "unissued and revoked clients remain configured protection" do
      assert {:ok, client} = Clients.create_client(%{name: "unissued", scopes: ["*"]})
      assert is_nil(client.token_digest)
      assert Clients.any_clients?()
      assert :ok = Clients.refresh_cache()
      assert Backplane.Clients.AuthCache.any_clients?()
      assert %{clients: 1, digests: 0} = Backplane.Clients.AuthCache.stats()
    end

    test "caller-selected credentials are rejected without retaining secrets" do
      for field <- [:token, :token_hash, :token_digest, :scheme, :credential_scheme] do
        attrs = Map.put(%{name: "rejected", scopes: ["*"]}, field, "do-not-retain")
        assert {:error, changeset} = Clients.issue_client(attrs)
        refute inspect(changeset) =~ "do-not-retain"
        refute Map.has_key?(changeset.params, to_string(field))
      end

      assert [] = Clients.list_clients()
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
        Backplane.Clients.AuthCache.mutate({:delete, client.id})
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
          [:backplane, :client_auth, :snapshot_loaded],
          fn _event, _measurements, _metadata, {target, test_pid, gate} ->
            first_client_query? =
              self() == target and
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
        Backplane.Clients.AuthCache.mutate({:delete, client.id})
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
        {:ok, :ok} ->
          :ok

        nil ->
          # OTP global locks retry with randomized backoff capped at eight seconds;
          # releasing the lock does not wake a task already in that backoff.
          assert Task.await(second_refresh, 10_000) == :ok
      end

      assert :ets.lookup(:backplane_clients_cache, client.id) == []
      assert :persistent_term.get(:backplane_clients_exist) == false
    end

    test "updates last_seen_at on successful verify" do
      {client, token} = insert_client(token: "my-secret-token")
      assert is_nil(client.last_seen_at)

      :ok = Clients.refresh_cache()

      Ecto.Adapters.SQL.Sandbox.allow(
        Backplane.Repo,
        self(),
        Process.whereis(Backplane.Clients.Activity)
      )

      assert {:ok, _verified} = Clients.verify_token(token)

      assert :ok = Backplane.Clients.Activity.flush()

      reloaded = Backplane.Repo.get!(Backplane.Clients.Client, client.id)
      assert reloaded.last_seen_at != nil
    end

    test "activity writes never move an existing timestamp backwards" do
      {client, token} = insert_client(token: "monotonic-activity-token")
      future = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      from(client in Backplane.Clients.Client, where: client.id == ^client.id)
      |> Repo.update_all(set: [last_seen_at: future])

      :ok = Clients.refresh_cache()
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(Backplane.Clients.Activity))
      assert {:ok, _} = Clients.verify_token(token)
      assert :ok = Backplane.Clients.Activity.flush()

      assert DateTime.compare(Repo.get!(Backplane.Clients.Client, client.id).last_seen_at, future) ==
               :eq
    end
  end

  defp assert_auth_work(expected, fun) do
    parent = self()
    tracer = spawn(fn -> forward_trace(parent) end)
    :erlang.trace_pattern({Bcrypt, :verify_pass, 2}, true, [])
    :erlang.trace_pattern({DBConnection, :prepare_execute, 4}, true, [])
    :erlang.trace_pattern({DBConnection, :execute, 4}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
      reference = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^reference}
      send(tracer, {:flush, self()})
      assert_receive {:bcrypt_trace_flushed, ^tracer}
      assert traced_auth_calls() == expected
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Bcrypt, :verify_pass, 2}, false, [])
      :erlang.trace_pattern({DBConnection, :prepare_execute, 4}, false, [])
      :erlang.trace_pattern({DBConnection, :execute, 4}, false, [])
      send(tracer, :stop)
    end
  end

  defp forward_trace(parent) do
    receive do
      :stop ->
        :ok

      {:flush, caller} ->
        send(caller, {:bcrypt_trace_flushed, self()})
        forward_trace(parent)

      message ->
        send(parent, {:bcrypt_trace, message})
        forward_trace(parent)
    end
  end

  defp traced_auth_calls(counts \\ %{bcrypt: 0, sql: 0}) do
    receive do
      {:bcrypt_trace, {:trace, _pid, :call, {Bcrypt, :verify_pass, _args}}} ->
        traced_auth_calls(Map.update!(counts, :bcrypt, &(&1 + 1)))

      {:bcrypt_trace, {:trace, _pid, :call, {DBConnection, function, _args}}}
      when function in [:prepare_execute, :execute] ->
        traced_auth_calls(Map.update!(counts, :sql, &(&1 + 1)))
    after
      0 -> counts
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
                   scopes: [permission]
                 })
      end

      refute Clients.scope_matches?(["host_agent.capture"], "host_agent.recall")
      refute Clients.scope_matches?(["host_agent.recall"], "host_agent.import")
      refute Clients.scope_matches?(["host_agent.import"], "host_agent.capture")
    end

    test "every canonical memory tool has exactly one permission class" do
      permissions = Backplane.MemoryPermissions.tool_permissions()

      assert map_size(permissions) == 56
      assert permissions["memory::get"] == "memory.read"
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
               Clients.upsert_from_config(%{name: "test", scopes: ["*"]})

      assert client.name == "test"
      assert client.scopes == ["*"]
      assert is_nil(client.token_digest)
    end

    test "updates existing client scopes on re-boot" do
      {:ok, original} =
        Clients.upsert_from_config(%{name: "test", scopes: ["*"]})

      {:ok, updated} =
        Clients.upsert_from_config(%{name: "test", scopes: ["docs::*"]})

      assert updated.id == original.id
      assert updated.scopes == ["docs::*"]
    end

    test "metadata seed preserves an existing issued credential and rejects old token import" do
      {client, token} = insert_client(name: "seeded")
      assert {:ok, seeded} = Clients.upsert_from_config(%{name: "seeded", scopes: ["docs::*"]})
      assert seeded.id == client.id
      assert seeded.token_digest == client.token_digest
      assert {:ok, _} = Clients.verify_token(token)

      assert {:error, changeset} =
               Clients.upsert_from_config(%{
                 name: "seeded",
                 token: "secret-import",
                 scopes: ["*"]
               })

      refute inspect(changeset) =~ "secret-import"
    end
  end
end
