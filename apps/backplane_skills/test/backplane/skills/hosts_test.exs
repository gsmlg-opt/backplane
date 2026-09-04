defmodule Backplane.Skills.HostsTest do
  use BackplaneSkills.DataCase, async: false

  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.{Entitlement, LegacyAlias, MemorySpace}
  alias Backplane.Repo
  alias Backplane.Skills.{AgentManage, Hosts}

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
  end

  describe "agent auth tokens" do
    test "creates auth tokens without creating agents" do
      assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "workstations"})

      assert String.starts_with?(token, "bha_")
      refute token == auth_token.token_hash
      assert Bcrypt.verify_pass(token, auth_token.token_hash)
      assert {:ok, ^token} = Hosts.reveal_auth_token(auth_token)
      assert Hosts.list_hosts() == []
      assert Enum.map(Hosts.list_auth_tokens(), & &1.name) == ["workstations"]
      assert :error = Hosts.verify_token(token)

      assert [%{token: listed_token, assigned_host: nil}] =
               Hosts.list_auth_tokens_with_assignments()

      assert listed_token.id == auth_token.id
    end

    test "requires globally unique token names" do
      assert {:ok, _auth_token, _token} = Hosts.create_auth_token(%{"name" => "workstations"})

      assert {:error, changeset} = Hosts.create_auth_token(%{"name" => "workstations"})
      assert {"has already been taken", _} = changeset.errors[:name]
    end

    test "blocks deleting an assigned token and hard-deletes it after unassigning" do
      assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "workstations"})

      assert {:ok, host} =
               Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [auth_token.id]})

      assert {:error, :assigned} = Hosts.delete_auth_token(auth_token)
      assert {:ok, _host} = Hosts.update_agent(host, %{"name" => "t430", "auth_token_ids" => []})
      assert {:ok, _auth_token} = Hosts.delete_auth_token(auth_token)

      refute Hosts.get_auth_token(auth_token.id)
      assert :error = Hosts.verify_token(token)
    end
  end

  describe "agents" do
    test "defaults, trims, and validates the registered memory scope" do
      assert {:ok, defaulted} = Hosts.create_agent(%{"name" => "default-scope"})
      assert defaulted.memory_scope == "proj_local"

      assert {:ok, scoped} =
               Hosts.create_agent(%{"name" => "scoped", "memory_scope" => "  project:alpha  "})

      assert scoped.memory_scope == "project:alpha"

      assert {:error, changeset} =
               Hosts.create_agent(%{"name" => "empty-scope", "memory_scope" => "   "})

      assert {"can't be blank", _} = changeset.errors[:memory_scope]
    end

    test "name-only update preserves a custom registered memory scope" do
      assert {:ok, host} =
               Hosts.create_agent(%{"name" => "before", "memory_scope" => "project:custom"})

      assert {:ok, updated} = Hosts.update_agent(host, %{"name" => "after"})
      assert updated.name == "after"
      assert updated.memory_scope == "project:custom"
    end

    test "creates an agent without tokens" do
      assert {:ok, host} = Hosts.create_agent(%{"name" => "t430"})

      assert host.name == "t430"
      assert Hosts.auth_token_ids_for_host(host) == []
      assert [%{name: "t430", auth_tokens: []}] = Hosts.list_hosts_with_auth_tokens()

      assert {:ok, %{scope: "proj_local", namespace: "private"}} =
               MemorySpaces.resolve_host_partition(host.id, nil, "private")
    end

    test "creates registry ownership in the create-with-token transaction" do
      assert {:ok, host, auth_token, plaintext} =
               Hosts.create_agent_with_token(%{
                 "name" => "tokenized-host",
                 "memory_scope" => "project:tokenized"
               })

      assert {:ok, verified, ^auth_token} = Hosts.verify_token(plaintext)
      assert verified.id == host.id

      assert {:ok, %{scope: "project:tokenized", namespace: "private"}} =
               MemorySpaces.resolve_host_partition(host.id, nil, "private")
    end

    test "assigns multiple auth tokens to one agent" do
      assert {:ok, first_token, first_plaintext} =
               Hosts.create_auth_token(%{"name" => "workstations-a"})

      assert {:ok, second_token, second_plaintext} =
               Hosts.create_auth_token(%{"name" => "workstations-b"})

      assert {:ok, host} =
               Hosts.create_agent(%{
                 "name" => "t430",
                 "auth_token_ids" => [first_token.id, second_token.id]
               })

      assert Hosts.auth_token_ids_for_host(host) |> Enum.sort() ==
               [first_token.id, second_token.id] |> Enum.sort()

      assert {:ok, verified_host, verified_token} = Hosts.verify_token(first_plaintext)
      assert verified_host.id == host.id
      assert verified_token.id == first_token.id

      assert {:ok, verified_host, verified_token} = Hosts.verify_token(second_plaintext)
      assert verified_host.id == host.id
      assert verified_token.id == second_token.id

      assert [%{name: "t430", auth_tokens: [_, _]}] = Hosts.list_hosts_with_auth_tokens()
    end

    test "updates agent name and token assignments" do
      assert {:ok, first_token, first_plaintext} =
               Hosts.create_auth_token(%{"name" => "workstations-a"})

      assert {:ok, second_token, second_plaintext} =
               Hosts.create_auth_token(%{"name" => "workstations-b"})

      assert {:ok, host} =
               Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [first_token.id]})

      assert {:ok, updated} =
               Hosts.update_agent(host, %{
                 "name" => "x1",
                 "auth_token_ids" => [second_token.id]
               })

      assert updated.name == "x1"
      assert Hosts.auth_token_ids_for_host(updated) == [second_token.id]
      assert :error = Hosts.verify_token(first_plaintext)
      assert {:ok, verified, _auth_token} = Hosts.verify_token(second_plaintext)
      assert verified.id == host.id
    end

    test "moves the memory default only when memory_scope changes" do
      assert {:ok, host} =
               Hosts.create_agent(%{"name" => "scope-owner", "memory_scope" => "scope:old"})

      [original_entitlement] =
        Repo.all(from(entitlement in Entitlement, where: entitlement.host_id == ^host.id))

      assert {:ok, renamed} = Hosts.update_agent(host, %{"name" => "renamed-owner"})

      [unchanged_entitlement] =
        Repo.all(from(entitlement in Entitlement, where: entitlement.host_id == ^host.id))

      assert unchanged_entitlement.updated_at == original_entitlement.updated_at

      assert {:ok, updated} =
               Hosts.update_agent(renamed, %{"memory_scope" => "scope:new"})

      assert updated.memory_scope == "scope:new"

      entitlements =
        Entitlement
        |> where([entitlement], entitlement.host_id == ^host.id)
        |> order_by(:scope)
        |> Repo.all()

      assert Enum.map(entitlements, &{&1.scope, &1.status, &1.default_capture}) == [
               {"scope:new", "active", true},
               {"scope:old", "active", false}
             ]
    end

    test "does not let one token belong to multiple agents" do
      assert {:ok, auth_token, _token} = Hosts.create_auth_token(%{"name" => "workstations"})

      assert {:ok, _first_host} =
               Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [auth_token.id]})

      assert {:error, changeset} =
               Hosts.create_agent(%{"name" => "x1", "auth_token_ids" => [auth_token.id]})

      assert {"is already assigned", _} = changeset.errors[:auth_token_ids]
    end

    test "deleting an agent revokes assigned tokens" do
      assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "workstations"})

      assert {:ok, host} =
               Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [auth_token.id]})

      assert {:ok, _host} = Hosts.delete_agent(host)

      refute Hosts.get_host(host.id)
      refute Hosts.get_auth_token(auth_token.id)
      assert :error = Hosts.verify_token(token)
      assert [] = Hosts.list_auth_tokens_with_assignments()

      space_id = MemorySpaces.private_host_space_id(host.id)
      alias_value = "host:#{host.id}"
      original_host_id = host.id
      assert %MemorySpace{status: "active"} = Repo.get!(MemorySpace, space_id)

      assert %LegacyAlias{memory_space_id: ^space_id} =
               Repo.one!(
                 from(alias_row in LegacyAlias, where: alias_row.alias_value == ^alias_value)
               )

      assert [
               %Entitlement{
                 host_id: ^original_host_id,
                 status: "revoked",
                 default_capture: false
               }
             ] =
               Repo.all(
                 from(entitlement in Entitlement,
                   where: entitlement.memory_space_id == ^space_id
                 )
               )

      assert Repo.aggregate(
               from(entitlement in Entitlement,
                 where:
                   entitlement.memory_space_id == ^space_id and
                     entitlement.host_id == ^original_host_id and
                     entitlement.scope == "proj_local" and
                     entitlement.namespace == "private"
               ),
               :count
             ) == 1
    end

    test "rejects an invalid token" do
      assert :error = Hosts.verify_token("missing-token")
    end
  end
end
