defmodule Backplane.Memory.ExactReadTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Memory.{Memories, Service}
  alias Backplane.Memory.Memories.Memory

  setup do
    owner = insert_host!()
    reader = insert_host!()
    {:ok, partition} = MemorySpaces.provision_private_host(owner, "exact_read")
    {:ok, _} = MemorySpaces.provision_private_host(reader, "reader_private")
    token = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_host_auth_tokens (id,name,token_hash,encrypted_token,inserted_at,updated_at) VALUES ($1,$2,'exact-read-test',$3,now(),now())",
      [Ecto.UUID.dump!(token), token, <<1>>]
    )

    Repo.query!(
      "INSERT INTO skill_host_agent_tokens (id,host_id,auth_token_id,inserted_at,updated_at) VALUES ($1,$2,$3,now(),now())",
      Enum.map([Ecto.UUID.generate(), reader, token], &Ecto.UUID.dump!/1)
    )

    shared_auth = %{
      kind: :host_agent,
      host_id: reader,
      auth_token_id: token,
      scopes: ["host_agent.recall"],
      source_client_id: "requester-client"
    }

    auth = %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory.read"],
      principal_metadata: %{"memory_partition_id" => "host:" <> owner}
    }

    %{
      owner: owner,
      reader: reader,
      token: token,
      partition: partition,
      auth: auth,
      shared_auth: shared_auth
    }
  end

  test "get exposes the shared schema and full canonical record with original provenance", c do
    memory =
      seed!(c, %{
        content: String.duplicate("complete content ", 400),
        source_client_id: "original-client",
        session_id: "original-session",
        tags: ["full"],
        metadata: %{
          "project" => "café project",
          "repository_sources" => [
            %{
              "repository_id" => "https://credential:secret@GitHub.com/org/repo.git",
              "checkout_root" => "/work/a",
              "cwd" => "/work/a/app"
            }
          ]
        }
      })

    tool = Enum.find(Service.tools(), &(&1.name == "memory::get"))
    assert tool.input_schema == Backplane.MemoryToolContract.tool!("memory::get").input_schema
    assert tool.permission == "memory.read"

    assert {:ok, result} =
             Service.call(
               "memory::get",
               %{
                 "id" => memory.id,
                 "project" => " cafe\u0301\nproject ",
                 "source" => %{"repository_id" => "git@github.com:org/repo.git"}
               },
               c.auth
             )

    assert result.mode == "online"
    assert result.authority == "canonical"
    assert result.consistency == "canonical"
    assert result.stale == false
    assert result.history_available == true
    record = result.record
    assert record.id == memory.id
    assert record.canonical_id == memory.id
    assert record.kind == "memory"
    assert record.content == memory.content
    assert record.memory_type == "semantic"
    assert record.tags == ["full"]
    assert record.lifecycle_state == "active"
    assert record.project == "café project"
    assert record.inserted_at == memory.inserted_at
    assert record.updated_at == memory.updated_at
    assert record.expires_at == nil

    assert record.provenance == %{
             source_host_id: c.owner,
             source_client_id: "original-client",
             agent_id: "source-agent",
             session_id: "original-session",
             repository_sources: [
               %{
                 "repository_id" => "github.com/org/repo",
                 "checkout_root" => "/work/a",
                 "cwd" => "/work/a/app"
               }
             ]
           }

    padded = String.duplicate(" ", 1_100) <> "café project"

    assert {:ok, %{record: %{id: id}}} =
             Service.call("memory::get", %{"id" => memory.id, "project" => padded}, c.auth)

    assert id == memory.id
  end

  test "source constraints must match one association and missing project cannot match", c do
    memory =
      seed!(c, %{
        metadata: %{
          "project" => "project-a",
          "repository_sources" => [
            %{"repository_id" => "github.com/org/a", "checkout_root" => "/a"},
            %{"repository_id" => "github.com/org/b", "checkout_root" => "/b"}
          ]
        }
      })

    for filters <- [
          %{"project" => "project-b"},
          %{"source" => %{"repository_id" => "github.com/org/a", "checkout_root" => "/b"}},
          %{"source" => %{"cwd" => "/unknown"}}
        ] do
      assert {:error, :not_found} =
               Service.call("memory::get", Map.put(filters, "id", memory.id), c.auth)
    end

    assert {:ok, _} =
             Service.call(
               "memory::get",
               %{
                 "id" => memory.id,
                 "source" => %{
                   "repository_id" => "github.com/org/b",
                   "checkout_root" => "/b"
                 }
               },
               c.auth
             )

    unknown = seed!(c)

    assert {:error, :not_found} =
             Service.call("memory::get", %{"id" => unknown.id, "project" => "project-a"}, c.auth)

    assert {:ok, %{record: record}} = Service.call("memory::get", %{"id" => unknown.id}, c.auth)
    assert record.project == nil
    assert record.provenance.source_client_id == nil
    assert record.provenance.session_id == nil
    assert record.provenance.repository_sources == []
  end

  test "public point read isolates all tuple fields and rechecks expiry, deletion and lifecycle",
       c do
    memory = seed!(c)
    assert {:ok, _} = Memories.public_get(memory.id, c.partition, %{})

    for partition <- [
          Map.put(c.partition, :memory_space_id, Ecto.UUID.generate()),
          Map.put(c.partition, :scope, "other"),
          Map.put(c.partition, :namespace, "other")
        ] do
      assert {:error, :not_found} = Memories.public_get(memory.id, partition, %{})
    end

    for attrs <- [
          %{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
          %{lifecycle_state: "archived"},
          %{lifecycle_state: "superseded", superseded_by: memory.id},
          %{lifecycle_state: "tombstoned", deleted_at: DateTime.utc_now()}
        ] do
      hidden = seed!(c, attrs)
      assert {:error, :not_found} = Service.call("memory::get", %{"id" => hidden.id}, c.auth)
    end

    assert {:error, :not_found} =
             Service.call("memory::get", %{"id" => Ecto.UUID.generate()}, c.auth)

    assert {:error, :not_found} =
             Service.call("memory::get", %{"id" => c.partition.memory_space_id}, c.auth)

    assert {:error, :invalid_arguments} =
             Service.call("memory::get", %{"id" => "device-slot"}, c.auth)

    assert {:error, :unauthorized} =
             Service.call("memory::get", %{"id" => memory.id}, %{c.auth | scopes: []})

    assert {:ok, %{results: rows}} = Service.call("memory::list", %{}, c.auth)
    assert Enum.any?(rows, &(&1.id == memory.id))

    Repo.update_all(from(m in Memory, where: m.id == ^memory.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, :not_found} = Service.call("memory::get", %{"id" => memory.id}, c.auth)
  end

  test "shared read allows foreign creators and independently rechecks the current grant", c do
    memory = seed!(c)
    access = grant!(c)
    claim = Map.take(access, [:access_id, :authority_version])

    assert {:ok, %{result: %{record: record}}} =
             Service.call_shared("memory::get", %{"id" => memory.id}, c.shared_auth, claim)

    assert record.provenance.source_host_id == c.owner
    refute record.provenance.source_host_id == c.reader
    assert {:ok, _} = Service.call_shared("memory::list", %{}, c.shared_auth, claim)

    assert {:ok, _} =
             MemorySpaces.revoke_host_access(
               operator(),
               access.access_id,
               1,
               "revoke after search"
             )

    assert {:error, :unauthorized} =
             Service.call_shared("memory::get", %{"id" => memory.id}, c.shared_auth, claim)
  end

  for mode <- [:revoke, :version, :credential] do
    test "shared read revalidates #{mode} after the point query", c do
      mode = unquote(mode)
      memory = seed!(c)
      access = grant!(c)
      claim = Map.take(access, [:access_id, :authority_version])
      handler = {__MODULE__, make_ref()}
      caller = self()

      :telemetry.attach(
        handler,
        [:backplane, :memory, :access, :stop],
        fn _, _, metadata, _ ->
          if metadata[:action] == "public_get" and metadata[:memory_id] == memory.id do
            result = change_before_release(mode, c, access)

            send(caller, {:changed_before_release, result})
          end
        end,
        nil
      )

      try do
        expected = unquote(if mode == :version, do: :authority_changed, else: :unauthorized)

        assert {:error, ^expected} =
                 Service.call_shared("memory::get", %{"id" => memory.id}, c.shared_auth, claim)

        assert_receive {:changed_before_release, _}
      after
        :telemetry.detach(handler)
      end
    end
  end

  defp change_before_release(:revoke, _c, access) do
    MemorySpaces.revoke_host_access(operator(), access.access_id, 1, "revoke before release")
  end

  defp change_before_release(:version, _c, access) do
    MemorySpaces.change_host_access(
      operator(),
      access.access_id,
      1,
      %{capabilities: [:read, :remember]},
      "change before release"
    )
  end

  defp change_before_release(:credential, c, _access) do
    Repo.query!("DELETE FROM skill_host_agent_tokens WHERE auth_token_id=$1", [
      Ecto.UUID.dump!(c.token)
    ])
  end

  test "direct read revalidates private capability before releasing content", c do
    memory = seed!(c)
    {:ok, access} = MemorySpaces.resolve_host_access(c.owner, :default, :read)
    handler = {__MODULE__, make_ref()}
    caller = self()

    :telemetry.attach(
      handler,
      [:backplane, :memory, :access, :stop],
      fn _, _, metadata, _ ->
        if metadata[:action] == "public_get" and metadata[:memory_id] == memory.id do
          result =
            MemorySpaces.revoke_host_access(
              operator(),
              access.access_id,
              1,
              "private revoke before release"
            )

          send(caller, {:revoked, result})
        end
      end,
      nil
    )

    try do
      assert {:error, :unauthorized} = Service.call("memory::get", %{"id" => memory.id}, c.auth)
      assert_receive {:revoked, {:ok, _}}
    after
      :telemetry.detach(handler)
    end
  end

  test "direct read cannot release the old partition after switching the default and revoking it",
       c do
    memory = seed!(c)
    {:ok, access} = MemorySpaces.resolve_host_access(c.owner, :default, :read)
    next_scope = "exact_read_next"
    handler = {__MODULE__, make_ref()}
    caller = self()

    :telemetry.attach(
      handler,
      [:backplane, :memory, :access, :stop],
      fn _, _, metadata, _ ->
        if metadata[:action] == "public_get" and metadata[:memory_id] == memory.id do
          result =
            with :ok <- MemorySpaces.update_default_scope(c.owner, next_scope),
                 {:ok, _} <-
                   MemorySpaces.revoke_host_access(
                     operator(),
                     access.access_id,
                     access.authority_version,
                     "revoke previous default before release"
                   ),
                 {:ok, current} <- MemorySpaces.resolve_host_access(c.owner, :default, :read) do
              {:ok, current}
            end

          send(caller, {:default_switched, result})
        end
      end,
      nil
    )

    try do
      result = Service.call("memory::get", %{"id" => memory.id}, c.auth)
      assert_receive {:default_switched, {:ok, current}}
      assert current.partition.scope == next_scope
      refute current.access_id == access.access_id

      assert {:error, :unauthorized} =
               MemorySpaces.resolve_host_access(c.owner, {:access_id, access.access_id}, :read)

      assert {:error, :unauthorized} = result
    after
      :telemetry.detach(handler)
    end
  end

  test "fully encoded replies reject oversize without truncating or changing access", c do
    memory = seed!(c, %{content: String.duplicate("\"", 270_000)})
    assert byte_size(memory.content) < 524_288

    assert {:error, :payload_too_large} =
             Service.call("memory::get", %{"id" => memory.id}, c.auth)

    access = grant!(c)
    claim = Map.take(access, [:access_id, :authority_version])

    assert {:error, :payload_too_large} =
             Service.call_shared("memory::get", %{"id" => memory.id}, c.shared_auth, claim)

    assert {:ok, current} =
             MemorySpaces.resolve_host_access(c.reader, {:access_id, access.access_id}, :read)

    assert current.authority_version == access.authority_version
  end

  test "canonical recall accepts a final rendered budget and skips oversized whole memories", c do
    memory = remember!(c, "budgetneedle user preference")

    args = %{
      "query" => "budgetneedle",
      "token_budget" => 1000,
      "channel_weights" => %{"fts" => 1}
    }

    assert {:ok, full} = Service.call("memory::recall", args, c.auth)
    assert [%{id: id, kind: :memory}] = full.results
    assert id == memory.id
    assert full.channels.fts.status == :ok
    assert full.channels.fts.count == 1
    assert full.used_tokens == byte_size(full.rendered_context)
    assert full.used_tokens > byte_size(memory.content)
    assert full.rendered_context =~ memory.content

    assert {:ok, %{results: [], used_tokens: 0, rendered_context: ""}} =
             Service.call(
               "memory::recall",
               Map.put(args, "token_budget", byte_size(memory.content)),
               c.auth
             )
  end

  test "disabled recall refuses current constraints without a legacy fallback", c do
    previous = :ets.lookup(:backplane_settings, "memory.recall.enabled")
    :ets.insert(:backplane_settings, {"memory.recall.enabled", false})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.recall.enabled")
      :ets.insert(:backplane_settings, previous)
    end)

    args = %{
      "query" => "disabled canonical recall",
      "project" => "project-a",
      "session_id" => "session-a",
      "agent_id" => "agent-a",
      "tag" => "tag-a",
      "token_budget" => 100
    }

    assert {:error, :recall_disabled} = Service.call("memory::recall", args, c.auth)
    assert {:error, :unauthorized} = Service.call("memory::recall", args, %{c.auth | scopes: []})
  end

  test "canonical recall applies supported constraints and rejects malformed values", c do
    memory =
      remember!(c, "constraintneedle user preference", metadata: %{"project" => "project-a"})

    facet = %{"dimension" => "exact_read_topic", "value" => "x"}

    Repo.insert!(
      Backplane.Memory.Facets.Dimension.changeset(
        %Backplane.Memory.Facets.Dimension{},
        %{name: facet["dimension"]}
      )
    )

    assert {:ok, 1} = Backplane.Memory.Facets.tag(memory.id, [facet])

    args = %{
      "query" => "constraintneedle",
      "project" => "project-a",
      "facets" => [facet],
      "temporal_hints" => %{"after" => "2026-01-01T00:00:00Z"},
      "entity_hints" => ["entity"],
      "include_working" => false,
      "token_budget" => 1000,
      "channel_weights" => %{"fts" => 1}
    }

    assert {:ok, %{results: [%{id: id}]}} = Service.call("memory::recall", args, c.auth)
    assert id == memory.id

    for filters <- [
          %{"project" => "project-b"},
          %{"facets" => [Map.put(facet, "value", "other")]},
          %{
            "temporal_hints" => %{
              "after" =>
                DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
            }
          }
        ] do
      assert {:ok, %{results: []}} =
               Service.call("memory::recall", Map.merge(args, filters), c.auth)
    end

    for {key, invalid} <- [
          {"project", %{}},
          {"facets", [%{"dimension" => "", "value" => "x"}]},
          {"temporal_hints", %{"after" => "not-a-date"}},
          {"entity_hints", [1]},
          {"include_working", "false"},
          {"token_budget", 0},
          {"channel_weights", %{"fts" => 0}}
        ] do
      assert {:error, :invalid_arguments} =
               Service.call("memory::recall", Map.put(args, key, invalid), c.auth)
    end

    assert {:error, :unauthorized} = Service.call("memory::recall", args, %{c.auth | scopes: []})

    assert {:error, :invalid_arguments} =
             Service.call("memory::list", %{"project" => "x"}, c.auth)

    assert {:error, :unauthorized} = Service.call("memory::list", %{scope: "foreign"}, c.auth)
  end

  defp remember!(c, content, opts \\ []) do
    partition =
      Map.merge(c.partition, %{
        host_id: c.owner,
        client_id: "host:" <> c.owner,
        agent_id: "source-agent"
      })

    assert {:ok, memory} =
             Memories.remember(content, Keyword.merge(Map.to_list(partition), opts))

    memory
  end

  defp seed!(c, attrs \\ %{}) do
    base =
      Map.merge(c.partition, %{
        host_id: c.owner,
        client_id: "host:" <> c.owner,
        content: "exact fixture #{Ecto.UUID.generate()}",
        agent_id: "source-agent"
      })

    values = Map.merge(base, attrs)
    values = Map.put(values, :content_hash, :crypto.hash(:sha256, values.content))
    %Memory{} |> Ecto.Changeset.change(values) |> Repo.insert!()
  end

  defp grant!(c) do
    {:ok, access} =
      MemorySpaces.grant_host_access(operator(), c.reader, c.partition, [:read],
        reason: "exact read test",
        expected_version: 0
      )

    access
  end

  defp operator, do: %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

  defp insert_host! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'exact_read',now(),now())",
      [Ecto.UUID.dump!(id), "exact-#{id}"]
    )

    id
  end
end
