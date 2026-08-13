defmodule Backplane.Memory.ServiceTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Memories, Observations, Service}
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Memories.{Evidence, RememberRequest}
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Workers.ProfileBuildWorker
  alias Backplane.Skills.Hosts

  defmodule RaisingLifecycleContext do
    def build(_project, _session_id, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:context_builder_called, :raise})
      raise "context builder secret"
    end
  end

  defmodule ExitingLifecycleContext do
    def build(_project, _session_id, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:context_builder_called, :exit})
      exit({:context_builder_failed, "context builder secret"})
    end
  end

  describe "tools/0" do
    test "exposes memory::* tools with handler functions" do
      names = Enum.map(Service.tools(), & &1.name)

      assert "memory::remember" in names
      assert "memory::recall" in names
      assert "memory::list" in names
      assert "memory::forget" in names
      assert "memory::stats" in names

      for tool <- Service.tools() do
        assert is_function(tool.handler, 2)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
      end
    end

    test "live registry exactly covers the canonical permission matrix" do
      keys =
        ~w(memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)

      previous = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

      for {key, value} <- [
            {"memory.tools", "all"},
            {"memory.pipeline.enabled", true},
            {"memory.replay_enabled", true},
            {"memory.replay_import_enabled", true}
          ],
          do: :ets.insert(:backplane_settings, {key, value})

      on_exit(fn ->
        Enum.each(previous, fn {key, rows} ->
          :ets.delete(:backplane_settings, key)
          if rows != [], do: :ets.insert(:backplane_settings, rows)
        end)
      end)

      live_names = Service.tools() |> Enum.map(& &1.name) |> MapSet.new()

      configured_names =
        Backplane.MemoryPermissions.tool_permissions()
        |> Map.keys()
        |> MapSet.new()

      assert live_names == configured_names
    end

    test "descriptor handlers enforce permission and authenticated host ownership" do
      host = create_memory_host!("descriptor-auth", "scope:descriptor")
      remember = Enum.find(Service.tools(), &(&1.name == "memory::remember"))
      args = %{"content" => "descriptor fact", "agent_id" => "agent"}

      assert {:error, :unauthorized} =
               remember.handler.(args, %{memory_auth(host) | scopes: ["memory.read"]})

      _second_host = create_memory_host!("descriptor-open-ambiguous")

      assert {:error, :unauthorized} =
               remember.handler.(args, %{kind: :open, client_id: nil, scopes: ["*"]})

      assert {:ok, %{id: id}} =
               remember.handler.(args, %{memory_auth(host) | scopes: ["memory.write"]})

      assert %MemorySchema{host_id: host_id, client_id: partition_id} =
               repo().get!(MemorySchema, id)

      assert host_id == host.id
      assert partition_id == "host:#{host.id}"
    end

    test "prefix is \"memory\"", do: assert(Service.prefix() == "memory")
  end

  describe "handle_remember/2" do
    test "schema accepts idempotency_key and handler supplies the direct server scope" do
      remember = Enum.find(Service.tools(), &(&1.name == "memory::remember"))
      assert remember.input_schema["properties"]["idempotency_key"] == %{"type" => "string"}

      host = create_memory_host!("direct-idempotent", "scope:direct")

      args = %{
        "content" => "idempotent service fact",
        "agent_id" => "service-agent",
        "idempotency_key" => "tool-call-1"
      }

      assert {:ok, first} = Service.handle_remember(args, memory_auth(host))
      assert {:ok, second} = Service.handle_remember(args, memory_auth(host))
      assert first == second
      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 1
      assert repo().one!(RememberRequest).idempotency_scope == "direct:host:#{host.id}"
    end

    test "persists a memory and returns id, scope, memory_type" do
      host = create_memory_host!("persist", "geo")

      args = %{
        "content" => "London is in the UK.",
        "agent_id" => "a",
        "scope" => "geo"
      }

      assert {:ok, %{id: id, scope: "geo", memory_type: "semantic"}} =
               Service.handle_remember(args, memory_auth(host))

      assert is_binary(id)

      assert %MemorySchema{host_id: host_id, client_id: partition, namespace: "private"} =
               repo().get!(MemorySchema, id)

      assert host_id == host.id
      assert partition == "host:#{host.id}"
    end

    test "applies semantic and the host's entitled scope defaults" do
      host = create_memory_host!("defaults", "scope:default")

      assert {:ok, %{id: id, scope: "scope:default", memory_type: "semantic"}} =
               Service.handle_remember(
                 %{"content" => "default contract", "agent_id" => "default-agent"},
                 memory_auth(host)
               )

      assert {:ok, memory} = Memories.trusted_get(id)
      assert memory.scope == "scope:default"
      assert memory.memory_type == "semantic"
    end

    test "fails closed for compatibility calls, spoofed ownership, and scope mismatch" do
      host = create_memory_host!("closed", "scope:allowed")

      assert {:error, :unauthorized} = Service.handle_remember(%{"content" => "x"})

      assert {:error, :invalid_arguments} =
               Service.handle_remember(
                 %{
                   "content" => "x",
                   "agent_id" => "a",
                   "host_id" => Ecto.UUID.generate(),
                   "client_id" => "host:attacker"
                 },
                 memory_auth(host)
               )

      assert {:error, :unauthorized} =
               Service.handle_remember(
                 %{"content" => "x", "agent_id" => "a", "scope" => "scope:foreign"},
                 memory_auth(host)
               )
    end

    test "returns descriptive error when content is missing" do
      host = create_memory_host!("missing-content")
      assert {:error, _} = Service.handle_remember(%{"agent_id" => "a"}, memory_auth(host))
    end
  end

  describe "handle_lifecycle_context/2" do
    setup do
      previous = Backplane.Settings.get("memory.inject_context")
      previous_context_module = Application.get_env(:backplane_memory, :context_module)
      :persistent_term.put({RaisingLifecycleContext, :owner}, self())
      :persistent_term.put({ExitingLifecycleContext, :owner}, self())

      on_exit(fn ->
        Backplane.Settings.set("memory.inject_context", previous)
        :persistent_term.erase({RaisingLifecycleContext, :owner})
        :persistent_term.erase({ExitingLifecycleContext, :owner})

        if previous_context_module do
          Application.put_env(:backplane_memory, :context_module, previous_context_module)
        else
          Application.delete_env(:backplane_memory, :context_module)
        end
      end)

      :ok
    end

    test "builds bounded context from the authenticated partition with a stable revision" do
      :ok = Backplane.Settings.set("memory.inject_context", "true")
      project = "lifecycle-project-#{System.unique_integer([:positive])}"
      host = create_memory_host!("lifecycle-context", "scope:trusted")

      assert {:ok, _trusted} =
               Memories.remember("#{project} trusted partition memory",
                 scope: "scope:trusted",
                 agent_id: "agent-1",
                 host_id: host.id,
                 client_id: "host:#{host.id}",
                 namespace: "private",
                 metadata: %{"project" => project}
               )

      assert {:ok, _decoy} =
               Memories.remember("#{project} caller project scope decoy",
                 scope: project,
                 agent_id: "agent-1",
                 host_id: host.id
               )

      repo().insert!(%Backplane.Memory.Profiles.Profile{
        project: project,
        top_concepts: %{"foreign-profile-secret" => 99},
        top_files: %{},
        patterns: %{},
        session_count: 1,
        total_observations: 1
      })

      args = %{
        "kind" => "session_start",
        "session_id" => "session-1",
        "project" => project,
        "agent_id" => "agent-1"
      }

      assert {:ok, result} = Service.handle_lifecycle_context(args, memory_auth(host))
      assert result.kind == "session_start"
      assert result.context =~ "trusted partition memory"
      refute result.context =~ "caller project scope decoy"
      refute result.context =~ "foreign-profile-secret"
      refute result.context =~ "Project Profile"
      assert result.source_revision == sha256(result.context)
      assert result.cached == false
      assert result.stale == false
      assert {:ok, generated_at, 0} = DateTime.from_iso8601(result.generated_at)
      assert {:ok, expires_at, 0} = DateTime.from_iso8601(result.expires_at)
      assert DateTime.diff(expires_at, generated_at, :second) == 900
      assert {:ok, _json} = Jason.encode(result)

      assert {:ok, second} = Service.handle_lifecycle_context(args, memory_auth(host))
      assert second.source_revision == result.source_revision
    end

    test "fails open with an empty contract when context construction raises" do
      :ok = Backplane.Settings.set("memory.inject_context", "true")
      Application.put_env(:backplane_memory, :context_module, RaisingLifecycleContext)
      host = create_memory_host!("lifecycle-raise")

      assert {:ok, %{context: nil, source_revision: nil, cached: false, stale: false}} =
               Service.handle_lifecycle_context(valid_lifecycle_args(), memory_auth(host))

      assert_received {:context_builder_called, :raise}
    end

    test "fails open with an empty contract when context construction exits" do
      :ok = Backplane.Settings.set("memory.inject_context", "true")
      Application.put_env(:backplane_memory, :context_module, ExitingLifecycleContext)
      host = create_memory_host!("lifecycle-exit")

      assert {:ok, %{context: nil, source_revision: nil, cached: false, stale: false}} =
               Service.handle_lifecycle_context(valid_lifecycle_args(), memory_auth(host))

      assert_received {:context_builder_called, :exit}
    end

    test "does not fail open authentication or validation errors" do
      Application.put_env(:backplane_memory, :context_module, RaisingLifecycleContext)
      host = create_memory_host!("lifecycle-errors")

      assert {:error, :unauthorized} =
               Service.handle_lifecycle_context(valid_lifecycle_args(), %{})

      assert {:error, :invalid_kind} =
               Service.handle_lifecycle_context(
                 %{valid_lifecycle_args() | "kind" => "invalid"},
                 memory_auth(host)
               )

      refute_received {:context_builder_called, _failure}
    end

    test "preserves the lifecycle kind and returns no revision when injection is disabled" do
      :ok = Backplane.Settings.set("memory.inject_context", "false")
      host = create_memory_host!("lifecycle-disabled")

      assert {:ok,
              %{
                kind: "pre_compact",
                context: nil,
                source_revision: nil,
                cached: false,
                stale: false
              }} =
               Service.handle_lifecycle_context(
                 %{
                   "kind" => "pre_compact",
                   "session_id" => "session-2",
                   "project" => "/workspace/project",
                   "agent_id" => "agent-2"
                 },
                 memory_auth(host)
               )
    end

    test "requires trusted auth and rejects invalid or caller-owned partition arguments" do
      host = create_memory_host!("lifecycle-validation")

      valid = %{
        "kind" => "session_start",
        "session_id" => "session-3",
        "project" => "/workspace/project",
        "agent_id" => "agent-3"
      }

      assert {:error, :unauthorized} = Service.handle_lifecycle_context(valid, %{})

      for {override, value} <- [
            {"host_id", Ecto.UUID.generate()},
            {"client_id", "host:attacker"},
            {"scope", "scope:attacker"},
            {"namespace", "team:attacker"},
            {"partition_id", "host:attacker"},
            {"memory_partition_id", "host:attacker"}
          ] do
        assert {:error, :invalid_arguments} =
                 Service.handle_lifecycle_context(
                   Map.put(valid, override, value),
                   memory_auth(host)
                 )
      end

      assert {:error, :invalid_kind} =
               Service.handle_lifecycle_context(
                 %{valid | "kind" => "SessionStart"},
                 memory_auth(host)
               )

      assert {:error, :invalid_session_id} =
               Service.handle_lifecycle_context(
                 %{valid | "session_id" => "  "},
                 memory_auth(host)
               )

      assert {:error, :invalid_project} =
               Service.handle_lifecycle_context(%{valid | "project" => ""}, memory_auth(host))
    end
  end

  describe "handle_verify/1" do
    test "returns the ordered durable evidence chain and derived counts" do
      host = create_memory_host!("verify")

      args = %{
        "content" => "verifiable service fact",
        "agent_id" => "service-agent",
        "idempotency_key" => "verify-one"
      }

      assert {:ok, %{id: memory_id}} = Service.handle_remember(args, memory_auth(host))

      assert {:ok, result} = Service.trusted_call("memory::verify", %{"memory_id" => memory_id})
      assert result.exists
      assert result.evidence_count == 1
      assert result.supporting_count == 1
      assert result.access_count == 0
      assert result.application_count == 0
      assert result.contradictory_evidence_count == 0
      assert result.contradiction_count == 0
      assert result.contradiction_relation_count == 0
      assert result.source_diversity == 1
      assert [%{source_type: "request", evidence_kind: "supports"}] = result.evidence
    end

    test "exposes request session attribution and derives session diversity" do
      host = create_memory_host!("verify-sessions")

      base = %{
        "content" => "session-aware service fact",
        "agent_id" => "service-agent"
      }

      assert {:ok, %{id: memory_id}} =
               Service.handle_remember(
                 Map.merge(base, %{"idempotency_key" => "session-a", "session_id" => "session-a"}),
                 memory_auth(host)
               )

      assert {:ok, %{id: ^memory_id}} =
               Service.handle_remember(
                 Map.merge(base, %{"idempotency_key" => "session-b", "session_id" => "session-b"}),
                 memory_auth(host)
               )

      assert {:ok, result} = Service.trusted_call("memory::verify", %{"memory_id" => memory_id})
      assert result.evidence_count == 2
      assert result.source_diversity == 2
      assert Enum.map(result.evidence, & &1.session_id) == ["session-a", "session-b"]
    end
  end

  describe "handle_recall/1" do
    test "flag-enabled authenticated recall uses V2 with exact authorized partition and provenance" do
      restore_recall_v2_settings_on_exit()
      restore_recall_task_supervisor_on_exit()

      supervisor =
        start_supervised!(
          {Task.Supervisor,
           name: String.to_atom("service-recall-#{System.unique_integer([:positive])}")}
        )

      Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)
      :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
      :ets.insert(:backplane_settings, {"memory.recall_v2.enabled", true})
      :ets.insert(:backplane_settings, {"memory.recall_trace_enabled", true})

      :ets.insert(
        :backplane_settings,
        {"memory.recall_channel_weights", %{"fts" => 1, "vector" => 0, "graph" => 0}}
      )

      host = create_memory_host!("recall-v2", "scope:recall-v2")
      auth = memory_auth(host)

      assert {:ok, %{id: memory_id}} =
               Service.handle_remember(
                 %{
                   "content" => "public v2 recall contract",
                   "agent_id" => "agent-v2",
                   "idempotency_key" => "public-v2-source"
                 },
                 auth
               )

      assert {:ok, result} =
               Service.handle_recall(
                 %{
                   "query" => "public v2 recall contract",
                   "limit" => 5,
                   "token_budget" => 100
                 },
                 auth
               )

      assert result.status == :ok
      assert is_binary(result.recall_run_id)
      assert result.used_tokens <= 100
      assert [%{id: ^memory_id, kind: :memory, source_ids: [_ | _]}] = result.results
      assert result.channels.fts.status == :ok

      assert {:ok, %Backplane.Memory.Recall.Run{status: "complete"}, [_ | _]} =
               Backplane.Memory.Recall.Store.get(result.recall_run_id, %{
                 host_id: host.id,
                 client_id: "host:#{host.id}",
                 scope: host.memory_scope,
                 namespace: "private"
               })

      assert {:ok, explanation} =
               Service.call(
                 "memory::recall_explain",
                 %{"recall_run_id" => result.recall_run_id},
                 %{auth | scopes: ["memory.read"]}
               )

      assert explanation.run.id == result.recall_run_id
      assert explanation.run.status == "complete"

      assert [%{candidate_id: ^memory_id, selected: true, source_refs: [_ | _]}] =
               explanation.candidates

      assert {:ok, trace_json} =
               Service.read_resource(
                 "memory://recall/#{result.recall_run_id}/trace",
                 %{auth | scopes: ["memory.read"]}
               )

      assert %{"run" => %{"id" => recall_run_id}, "candidates" => [_ | _]} =
               Jason.decode!(trace_json)

      assert recall_run_id == result.recall_run_id

      other_host = create_memory_host!("recall-v2-foreign", "scope:recall-v2")

      assert {:error, :not_found} =
               Service.call(
                 "memory::recall_explain",
                 %{"recall_run_id" => result.recall_run_id},
                 %{memory_auth(other_host) | scopes: ["memory.read"]}
               )

      assert {:error, :not_found} =
               Service.read_resource(
                 "memory://recall/#{result.recall_run_id}/trace",
                 %{memory_auth(other_host) | scopes: ["memory.read"]}
               )

      assert {:error, :unsupported_recall_v2_filter} =
               Service.handle_recall(%{"query" => "public", "agent_id" => "legacy-filter"}, auth)

      assert {:error, :unsupported_recall_v2_filter} =
               Service.handle_recall(%{"query" => "public", "tag" => "legacy-filter"}, auth)

      assert {:error, :invalid_arguments} =
               Service.handle_recall(%{"query" => "public", "surprise" => true}, auth)
    end

    test "flag-disabled recall preserves the exact legacy response contract" do
      restore_recall_v2_settings_on_exit()
      :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
      :ets.insert(:backplane_settings, {"memory.recall_v2.enabled", false})

      {:ok, memory} =
        Memories.remember("legacy parity recall",
          agent_id: "legacy-agent",
          host_id: "legacy-host",
          scope: "legacy-scope"
        )

      assert {:ok, %{results: [%{id: id} = result]} = response} =
               Service.trusted_call("memory::recall", %{
                 "query" => "legacy parity recall",
                 "scope" => "legacy-scope"
               })

      assert id == memory.id
      assert Map.keys(response) == [:results]
      refute Map.has_key?(result, :kind)
    end

    test "falls back to ranked lexical search when the configured embedder returns 503" do
      scope = "service-embedding-503-fallback-#{System.unique_integer([:positive])}"

      {:ok, strongest} =
        Memories.remember(
          "gateway fallback signal gateway fallback signal gateway fallback signal",
          agent_id: "service-fallback-agent",
          host_id: "service-fallback-host",
          scope: scope
        )

      {:ok, weaker} =
        Memories.remember("gateway fallback signal",
          agent_id: "service-fallback-agent",
          host_id: "service-fallback-host",
          scope: scope
        )

      assert is_nil(strongest.embedding)
      assert is_nil(weaker.embedding)

      test_pid = self()
      previous_req_options = Req.default_options()
      previous_embed_model = Application.fetch_env(:backplane_memory, :embed_model)

      adapter = fn request ->
        send(test_pid, {:embedding_request, Jason.decode!(request.body)})
        {request, Req.Response.new(status: 503, body: %{"error" => "unavailable"})}
      end

      Req.default_options(Keyword.put(previous_req_options, :adapter, adapter))
      Application.put_env(:backplane_memory, :embed_model, "service-fallback-test-model")

      on_exit(fn ->
        Req.default_options(previous_req_options)

        case previous_embed_model do
          {:ok, model} -> Application.put_env(:backplane_memory, :embed_model, model)
          :error -> Application.delete_env(:backplane_memory, :embed_model)
        end
      end)

      assert {:ok, %{results: results}} =
               Service.trusted_call("memory::recall", %{
                 "query" => "gateway fallback signal",
                 "limit" => 2,
                 "scope" => scope
               })

      assert_receive {:embedding_request, %{"model" => "service-fallback-test-model"}}
      assert Enum.map(results, & &1.id) == [strongest.id, weaker.id]
    end

    test "falls back to text search when embedding is not configured" do
      {:ok, mem} =
        Memories.remember("service recall fallback",
          agent_id: "a",
          host_id: "h",
          scope: "service"
        )

      assert {:ok, %{results: [%{id: id}]}} =
               Service.trusted_call("memory::recall", %{
                 "query" => "service recall",
                 "limit" => 5,
                 "scope" => "service"
               })

      assert id == mem.id
    end

    test "returns an empty result set when no lexical memory matches" do
      assert {:ok, %{results: []}} =
               Service.trusted_call("memory::recall", %{"query" => "no-such-recall-contract-term"})
    end

    test "applies scope, agent, host, and tag filters" do
      {:ok, target} =
        Memories.remember("filtered recall contract target",
          agent_id: "filtered-agent",
          host_id: "filtered-host",
          scope: "filtered-scope",
          tags: ["filtered-tag"]
        )

      {:ok, _decoy} =
        Memories.remember("filtered recall contract decoy",
          agent_id: "other-agent",
          host_id: "other-host",
          scope: "other-scope",
          tags: ["other-tag"]
        )

      assert {:ok, %{results: [%{id: id}]}} =
               Service.trusted_call("memory::recall", %{
                 "query" => "filtered recall contract",
                 "scope" => "filtered-scope",
                 "agent_id" => "filtered-agent",
                 "host_id" => "filtered-host",
                 "tag" => "filtered-tag"
               })

      assert id == target.id
    end

    test "defaults the result limit to 10" do
      scope = "recall-default-limit-#{System.unique_integer([:positive])}"

      for i <- 1..11 do
        {:ok, _} =
          Memories.remember("default recall contract item #{i}",
            agent_id: "recall-limit-agent",
            host_id: "recall-limit-host",
            scope: scope
          )
      end

      assert {:ok, %{results: results}} =
               Service.trusted_call("memory::recall", %{
                 "query" => "default recall contract",
                 "scope" => scope
               })

      assert length(results) == 10
    end

    test "returns error when query is missing" do
      assert {:error, _} = Service.trusted_call("memory::recall", %{})
    end
  end

  describe "handle_list/1" do
    test "returns memories with id, content, scope" do
      {:ok, _} = Memories.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h")

      assert {:ok, %{results: [%{id: _, content: _, scope: _}]}} =
               Service.trusted_call("memory::list", %{"q" => "Tokyo"})
    end

    test "returns an empty result set when filters do not match" do
      assert {:ok, %{results: []}} =
               Service.trusted_call("memory::list", %{"scope" => "missing-list-contract-scope"})
    end

    test "applies type, scope, agent, tag, and substring filters" do
      {:ok, target} =
        Memories.remember("list contract target",
          type: "procedural",
          scope: "list-scope",
          agent_id: "list-agent",
          host_id: "list-host",
          tags: ["list-tag"]
        )

      {:ok, _decoy} =
        Memories.remember("list contract decoy",
          type: "semantic",
          scope: "other-list-scope",
          agent_id: "other-list-agent",
          host_id: "list-host",
          tags: ["other-list-tag"]
        )

      assert {:ok, %{results: [%{id: id}]}} =
               Service.trusted_call("memory::list", %{
                 "type" => "procedural",
                 "scope" => "list-scope",
                 "agent_id" => "list-agent",
                 "tag" => "list-tag",
                 "q" => "contract target"
               })

      assert id == target.id
    end

    test "defaults to the newest 50 results at offset zero" do
      scope = "list-default-limit-#{System.unique_integer([:positive])}"
      base_time = ~U[2026-01-01 00:00:00.000000Z]

      entries =
        for i <- 1..51 do
          id = Ecto.UUID.generate()
          content = "list default contract #{i}"
          timestamp = DateTime.add(base_time, i, :second)

          {id,
           %{
             id: id,
             content: content,
             memory_type: "semantic",
             scope: scope,
             agent_id: "list-limit-agent",
             host_id: "list-limit-host",
             content_hash: :crypto.hash(:sha256, content),
             inserted_at: timestamp,
             updated_at: timestamp
           }}
        end

      {51, nil} = repo().insert_all(MemorySchema, Enum.map(entries, &elem(&1, 1)))

      assert {:ok, %{results: results}} =
               Service.trusted_call("memory::list", %{"scope" => scope})

      expected_ids = entries |> Enum.reverse() |> Enum.take(50) |> Enum.map(&elem(&1, 0))
      assert Enum.map(results, & &1.id) == expected_ids
    end
  end

  describe "handle_forget/1" do
    test "soft-deletes a memory" do
      {:ok, mem} = Memories.remember("Berlin is in Germany.", agent_id: "a", host_id: "h")

      assert {:ok, %{id: id, status: "deleted"}} =
               Service.trusted_call("memory::forget", %{"id" => mem.id})

      assert id == mem.id
      assert {:error, :not_found} = Memories.trusted_get(mem.id)
    end

    test "returns error for unknown id" do
      assert {:error, "memory not found"} =
               Service.trusted_call("memory::forget", %{"id" => Ecto.UUID.generate()})
    end

    test "returns a stable error when hard deletion would discard provenance" do
      previous = Backplane.Settings.get("memory.hard_delete_enabled")
      :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
      on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

      {:ok, mem} = Memories.remember("service retained", agent_id: "a", host_id: "h")

      assert {:error, "memory provenance retained"} =
               Service.trusted_call("memory::forget", %{"id" => mem.id})

      assert {:ok, ^mem} = Memories.trusted_get(mem.id)
    end

    test "returns an error when id is missing" do
      assert {:error, "id is required and must be a string"} =
               Service.trusted_call("memory::forget", %{})
    end
  end

  describe "handle_stats/1" do
    test "returns an empty collection when there are no memories" do
      assert {:ok, %{stats: []}} = Service.trusted_call("memory::stats", %{})
    end

    test "returns stats grouped by memory_type" do
      {:ok, _} = Memories.remember("s1", agent_id: "a", host_id: "h", type: "semantic")
      assert {:ok, %{stats: stats}} = Service.trusted_call("memory::stats", %{})
      assert Enum.any?(stats, &(&1.memory_type == "semantic"))
    end
  end

  describe "handle_profile/1" do
    test "returns building for a missing profile and the cached profile afterward" do
      project = "profile-contract-#{System.unique_integer([:positive])}"
      host = create_memory_host!("profile", project)
      args = Map.put(trusted_args(host), "project", project)

      assert {:ok, %{status: "building"}} = Service.trusted_call("memory::profile", args)

      assert {:ok,
              %{
                project: ^project,
                top_concepts: %{},
                top_files: %{},
                patterns: %{},
                session_count: 0,
                total_observations: 0
              }} = Service.trusted_call("memory::profile", args)
    end

    test "returns an error when project is missing" do
      assert {:error, "project is required"} = Service.trusted_call("memory::profile", %{})
    end
  end

  describe "handle_file_history/1" do
    test "returns matching observations and honors exclude_session" do
      {:ok, _} = Observations.record("file-history-mine", "changed lib/contract.ex")
      {:ok, other} = Observations.record("file-history-other", "updated lib/contract.ex")

      assert {:ok, %{results: [%{id: id, session_id: "file-history-other"}]}} =
               Service.trusted_call("memory::file_history", %{
                 "files" => ["lib/contract.ex"],
                 "exclude_session" => "file-history-mine",
                 "limit" => 1
               })

      assert id == other.id
    end

    test "returns an empty result set for unmatched files" do
      assert {:ok, %{results: []}} =
               Service.trusted_call("memory::file_history", %{"files" => ["missing/contract.ex"]})
    end

    test "defaults the result limit to the newest 50 observations" do
      session_id = "file-history-default-limit"
      path = "lib/file_history_default_limit.ex"
      base_time = ~U[2026-01-01 00:00:00.000000Z]

      entries =
        for i <- 1..51 do
          id = Ecto.UUID.generate()

          {id,
           %{
             id: id,
             session_id: session_id,
             content: "file history default contract #{i}",
             files: %{"paths" => [path]},
             created_at: DateTime.add(base_time, i, :second)
           }}
        end

      {51, nil} = repo().insert_all(Observation, Enum.map(entries, &elem(&1, 1)))

      assert {:ok, %{results: results}} =
               Service.trusted_call("memory::file_history", %{"files" => [path]})

      expected_ids = entries |> Enum.reverse() |> Enum.take(50) |> Enum.map(&elem(&1, 0))
      assert Enum.map(results, & &1.id) == expected_ids
    end

    test "returns an error when files is missing" do
      assert {:error, "files is required and must be an array"} =
               Service.trusted_call("memory::file_history", %{})
    end
  end

  describe "handle_sessions/1" do
    test "returns an empty result set when no sessions exist" do
      assert {:ok, %{sessions: []}} =
               Service.trusted_call("memory::sessions", %{
                 "session_id" => "missing-#{System.unique_integer([:positive])}"
               })
    end

    test "does not treat matching legacy session rows as production reads" do
      {:ok, target} = Observations.register_session("session-contract-target", "project-a")
      {:ok, _decoy} = Observations.register_session("session-contract-decoy", "project-b")

      assert {:ok, %{sessions: []}} =
               Service.trusted_call("memory::sessions", %{"project" => "project-a"})

      assert target.project == "project-a"
    end

    test "does not load legacy sessions into the bounded default page" do
      project = "sessions-default-limit"
      base_time = ~U[2026-01-01 00:00:00.000000Z]

      entries =
        for i <- 1..21 do
          session_id = "sessions-default-#{i}"

          {session_id,
           %{
             session_id: session_id,
             project: project,
             started_at: DateTime.add(base_time, i, :second)
           }}
        end

      {21, nil} = repo().insert_all(Session, Enum.map(entries, &elem(&1, 1)))

      assert {:ok, %{sessions: sessions}} =
               Service.trusted_call("memory::sessions", %{"project" => project})

      assert sessions == []
    end
  end

  describe "handle_timeline/1" do
    test "returns an empty timeline when there are no observations" do
      assert {:ok, %{timeline: []}} =
               Service.trusted_call("memory::timeline", %{
                 "session_id" => "missing-#{System.unique_integer([:positive])}"
               })
    end

    test "does not expose matching legacy observations" do
      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()

      {3, nil} =
        repo().insert_all(Observation, [
          %{
            id: first_id,
            session_id: "timeline-a",
            content: "timeline contract first",
            created_at: ~U[2026-01-01 00:00:01.000000Z]
          },
          %{
            id: second_id,
            session_id: "timeline-a",
            content: "timeline contract second",
            created_at: ~U[2026-01-01 00:00:02.000000Z]
          },
          %{
            id: other_id,
            session_id: "timeline-b",
            content: "timeline contract other",
            created_at: ~U[2026-01-01 00:00:03.000000Z]
          }
        ])

      assert {:ok, %{timeline: []}} =
               Service.trusted_call("memory::timeline", %{"session_id" => "timeline-a"})
    end

    test "does not load legacy observations into the bounded default page" do
      session_id = "timeline-default-limit"
      base_time = ~U[2026-01-01 00:00:00.000000Z]

      entries =
        for i <- 1..51 do
          id = Ecto.UUID.generate()

          {id,
           %{
             id: id,
             session_id: session_id,
             content: "timeline default contract #{i}",
             created_at: DateTime.add(base_time, i, :second)
           }}
        end

      {51, nil} = repo().insert_all(Observation, Enum.map(entries, &elem(&1, 1)))

      assert {:ok, %{timeline: []}} =
               Service.trusted_call("memory::timeline", %{"session_id" => session_id})
    end
  end

  describe "handle_consolidate/1" do
    test "queues using session_id as the worker argument without validating the session" do
      missing_session = "missing-session-#{System.unique_integer([:positive])}"
      host = create_memory_host!("consolidate")
      args = Map.put(trusted_args(host), "session_id", missing_session)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{status: "queued", session_id: ^missing_session}} =
                 Service.trusted_call("memory::consolidate", args)

        assert Oban.Testing.assert_enqueued(
                 repo(),
                 worker: ProfileBuildWorker,
                 args: Map.put(trusted_args(host), "project", missing_session)
               )
      end)
    end

    test "returns an error when session_id is missing" do
      assert {:error, "session_id is required"} = Service.trusted_call("memory::consolidate", %{})
    end
  end

  describe "handle_compress_file/1 provenance" do
    test "retries are effect-free and only contributing observations are cited" do
      restore_event_settings_on_exit()
      enable_dual_write()
      path = "lib/compression_provenance.ex"
      {:ok, excluded} = authoritative_observation("compress-excluded", "excluded #{path}")

      {:ok, contributing} =
        authoritative_observation(
          "compress-contributing",
          String.duplicate("x", 4_000) <> " #{path}"
        )

      args =
        Map.merge(compression_partition(), %{
          "file_path" => path,
          "agent_id" => "compressor"
        })

      assert {:ok, %{status: "compressed", memory_id: memory_id}} =
               Service.trusted_call("memory::compress_file", args)

      assert [
               %{source_type: "request"},
               %{
                 source_type: "observation",
                 source_id: contributing_id,
                 session_id: "compress-contributing",
                 agent_id: "compressor",
                 host_id: "host-a",
                 evidence_kind: "derives"
               }
             ] = Memories.list_evidence(memory_id)

      assert contributing_id == contributing.id
      refute Enum.any?(Memories.list_evidence(memory_id), &(&1.source_id == excluded.id))

      counts = {repo().aggregate(RememberRequest, :count), repo().aggregate(Evidence, :count)}
      assert {:ok, %{memory_id: ^memory_id}} = Service.trusted_call("memory::compress_file", args)

      assert counts ==
               {repo().aggregate(RememberRequest, :count), repo().aggregate(Evidence, :count)}
    end

    test "excludes same-path observations from other partitions while retaining same-partition agents" do
      restore_event_settings_on_exit()
      enable_dual_write()
      path = "lib/compression_tenant.ex"

      {:ok, owner} = authoritative_observation("owner-session", "owner changed #{path}")

      {:ok, _} =
        authoritative_observation("other-host-session", "other host changed #{path}",
          host_id: "host-b"
        )

      {:ok, other_agent} =
        authoritative_observation("other-agent-session", "other agent changed #{path}",
          agent_id: "agent-b"
        )

      assert {:ok, %{memory_id: memory_id}} =
               Service.trusted_call("memory::compress_file", %{
                 "file_path" => path,
                 "agent_id" => "compressor",
                 "host_id" => "host-a",
                 "client_id" => "client-a",
                 "scope" => "scope-a",
                 "namespace" => "private"
               })

      evidence = Memories.list_evidence(memory_id)
      assert [%{source_type: "request"} | observations] = evidence

      assert MapSet.new(Enum.map(observations, & &1.source_id)) ==
               MapSet.new([owner.id, other_agent.id])
    end
  end

  describe "enabled?/0" do
    test "false by default (opt-in via services.memory.enabled)" do
      refute Service.enabled?()
    end
  end

  defp authoritative_observation(session_id, content, opts \\ []) do
    partition = %{
      host_id: Keyword.get(opts, :host_id, "host-a"),
      client_id: Keyword.get(opts, :client_id, "client-a"),
      scope: Keyword.get(opts, :scope, "scope-a"),
      namespace: Keyword.get(opts, :namespace, "private")
    }

    Observations.record(session_id, content,
      host_id: partition.host_id,
      client_id: partition.client_id,
      agent_id: Keyword.get(opts, :agent_id, "compressor"),
      trusted_partition: partition
    )
  end

  defp compression_partition do
    %{
      "host_id" => "host-a",
      "client_id" => "client-a",
      "scope" => "scope-a",
      "namespace" => "private"
    }
  end

  defp create_memory_host!(suffix, memory_scope \\ "proj_local") do
    {:ok, host, _auth_token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "memory-service-#{suffix}-#{System.unique_integer([:positive])}",
        "memory_scope" => memory_scope
      })

    host
  end

  defp memory_auth(host) do
    %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory::*"],
      principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
    }
  end

  defp trusted_args(host) do
    %{
      "host_id" => host.id,
      "client_id" => "host:#{host.id}",
      "scope" => host.memory_scope,
      "namespace" => "private"
    }
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp valid_lifecycle_args do
    %{
      "kind" => "session_start",
      "session_id" => "session-fail-open",
      "project" => "/workspace/project",
      "agent_id" => "agent-fail-open"
    }
  end

  defp restore_event_settings_on_exit do
    keys = ["memory.pipeline.enabled", "memory.events.enabled", "memory.events.dual_write"]
    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)
  end

  defp restore_recall_v2_settings_on_exit do
    keys = [
      "memory.pipeline.enabled",
      "memory.recall_v2.enabled",
      "memory.recall_trace_enabled",
      "memory.recall_channel_weights"
    ]

    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)
  end

  defp restore_recall_task_supervisor_on_exit do
    previous = Application.get_env(:backplane_memory, :recall_task_supervisor)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :recall_task_supervisor, previous),
        else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
    end)
  end

  defp enable_dual_write do
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.events.enabled", true})
    :ets.insert(:backplane_settings, {"memory.events.dual_write", true})
  end
end
