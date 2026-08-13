defmodule Backplane.Memory.Memories.EvidenceTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.{Evidence, RememberRequest}

  describe "direct remember request idempotency" do
    test "unkeyed calls retain one request evidence row per explicit remember" do
      opts = [agent_id: "agent", host_id: "host"]

      assert {:ok, first} = Memories.remember("unkeyed provenance", opts)
      assert {:ok, second} = Memories.remember("unkeyed provenance", opts)
      assert first.id == second.id
      assert repo().aggregate(RememberRequest, :count) == 2
      assert repo().aggregate(Evidence, :count) == 2
      assert Enum.all?(repo().all(RememberRequest), &(&1.idempotency_scope == "unkeyed"))
    end

    test "a newly created unkeyed memory verifies with evidence" do
      assert {:ok, memory} =
               Memories.remember("new unkeyed provenance", agent_id: "agent", host_id: "host")

      assert {:ok, verification} = Memories.trusted_verify(memory.id)
      assert verification.evidence_count == 1
      assert [%{source_type: "request", evidence_kind: "supports"}] = verification.evidence
    end

    test "same key and request returns one memory, request, and evidence row" do
      opts = direct_opts("same")

      assert {:ok, first} = Memories.remember("stable fact", opts)
      assert {:ok, second} = Memories.remember("stable fact", opts)
      assert first.id == second.id
      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 1
    end

    test "same key with a changed effective request conflicts without partial effects" do
      opts = direct_opts("conflict")
      assert {:ok, memory} = Memories.remember("first fact", opts)

      assert {:error, :idempotency_conflict} = Memories.remember("changed fact", opts)
      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 1
      assert Memories.trusted_count() == 1
      assert {:ok, stored} = Memories.trusted_get(memory.id)
      assert stored.content == "first fact"
    end

    test "independent keys for one exact candidate reuse memory and add request evidence" do
      assert {:ok, first} = Memories.remember("shared fact", direct_opts("one"))
      assert {:ok, second} = Memories.remember("shared fact", direct_opts("two"))

      assert first.id == second.id
      assert repo().aggregate(RememberRequest, :count) == 2
      assert repo().aggregate(Evidence, :count) == 2
    end

    test "exact candidates are partitioned by namespace, type, project, and client" do
      base = [agent_id: "agent", host_id: "host", scope: "scope"]

      variants = [
        base,
        Keyword.put(base, :namespace, "team:one"),
        Keyword.put(base, :type, "procedural"),
        Keyword.put(base, :metadata, %{"project" => "one"}),
        Keyword.put(base, :client_id, "client-one")
      ]

      ids =
        Enum.map(variants, fn opts ->
          {:ok, memory} = Memories.remember("partitioned", opts)
          memory.id
        end)

      assert length(Enum.uniq(ids)) == length(variants)
    end

    test "non-string project metadata shares the empty project partition and canonical hash" do
      opts = Keyword.put(direct_opts("non-string"), :metadata, %{"project" => false})
      assert {:ok, first} = Memories.remember("non-string project", opts)

      retry_opts = Keyword.put(direct_opts("non-string"), :metadata, %{"project" => 42})
      assert {:ok, retry} = Memories.remember("non-string project", retry_opts)
      assert retry.id == first.id

      independent_opts =
        Keyword.put(direct_opts("non-string-map"), :metadata, %{"project" => %{"nested" => true}})

      assert {:ok, independent} = Memories.remember("non-string project", independent_opts)
      assert independent.id == first.id
      assert repo().aggregate(RememberRequest, :count) == 2
      assert repo().aggregate(Evidence, :count) == 2
    end

    test "an idempotency key requires a trusted server-side scope" do
      assert {:error, :idempotency_scope_required} =
               Memories.remember("fact",
                 agent_id: "agent",
                 host_id: "host",
                 idempotency_key: "key"
               )

      assert Memories.trusted_count() == 0
    end

    test "rejects an empty idempotency key without raising or writing" do
      assert {:error, :invalid_idempotency_key} =
               Memories.remember("fact",
                 agent_id: "agent",
                 host_id: "host",
                 idempotency_scope: "direct",
                 idempotency_key: "  "
               )

      assert Memories.trusted_count() == 0
    end
  end

  describe "evidence verification" do
    test "persists request and typed evidence atomically and deduplicates exact sources" do
      source = session_evidence("source-session")

      assert {:ok, memory} =
               Memories.remember(
                 "typed provenance",
                 direct_opts("typed") ++ [evidence: [source, source]]
               )

      assert [
               %{source_type: "request", evidence_kind: "supports"},
               %{
                 source_type: "session",
                 source_id: "source-host:source-session",
                 evidence_kind: "derives",
                 support_score: 0.9,
                 excerpt: "source excerpt"
               }
             ] = Memories.list_evidence(memory.id)
    end

    test "keyed retries canonicalize typed evidence independently of list and map order" do
      first = session_evidence("first", %{excerpt: "one"})
      second = session_evidence("second", %{excerpt: "two"})

      opts = direct_opts("canonical-evidence")

      assert {:ok, memory} =
               Memories.remember("canonical typed", opts ++ [evidence: [first, second]])

      string_keyed_second =
        second
        |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.new()

      assert {:ok, ^memory} =
               Memories.remember(
                 "canonical typed",
                 opts ++ [evidence: [string_keyed_second, first]]
               )

      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 3
    end

    test "changed typed evidence conflicts for the same keyed request without partial effects" do
      opts = direct_opts("changed-evidence")

      assert {:ok, memory} =
               Memories.remember(
                 "changed typed",
                 opts ++ [evidence: [session_evidence("source")]]
               )

      changed = session_evidence("source", %{support_score: 0.4})

      assert {:error, :idempotency_conflict} =
               Memories.remember("changed typed", opts ++ [evidence: [changed]])

      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 2
      assert {:ok, %{evidence_count: 1}} = Memories.trusted_verify(memory.id)
    end

    test "rejects one source with conflicting durable attributes before writing" do
      first = session_evidence("source")
      conflicting = session_evidence("source", %{excerpt: "different"})

      assert {:error, :conflicting_evidence} =
               Memories.remember(
                 "conflicting typed",
                 direct_opts("conflicting-typed") ++ [evidence: [first, conflicting]]
               )

      assert Memories.trusted_count() == 0
      assert repo().aggregate(RememberRequest, :count) == 0
      assert repo().aggregate(Evidence, :count) == 0
    end

    test "rejects malformed typed evidence before writing" do
      invalid =
        session_evidence("source")
        |> Map.put(:source_event_id, Ecto.UUID.generate())

      assert {:error, :invalid_evidence} =
               Memories.remember(
                 "invalid typed",
                 direct_opts("invalid-typed") ++ [evidence: [invalid]]
               )

      assert Memories.trusted_count() == 0
      assert repo().aggregate(RememberRequest, :count) == 0
      assert repo().aggregate(Evidence, :count) == 0
    end

    test "rejects typed evidence that is not JSON safe without writing" do
      invalid = session_evidence("invalid-json", %{excerpt: <<255>>})

      assert {:error, :not_json_safe} =
               Memories.remember(
                 "invalid JSON typed",
                 direct_opts("invalid-json-typed") ++ [evidence: [invalid]]
               )

      assert Memories.trusted_count() == 0
      assert repo().aggregate(RememberRequest, :count) == 0
      assert repo().aggregate(Evidence, :count) == 0
    end

    test "an invalid typed source foreign key rolls back memory, request, and all evidence" do
      invalid_source = %{
        source_observation_id: Ecto.UUID.generate(),
        evidence_kind: "derives",
        support_score: 0.8
      }

      assert {:error, %Ecto.Changeset{}} =
               Memories.remember(
                 "missing typed source",
                 direct_opts("missing-source") ++ [evidence: [invalid_source]]
               )

      assert Memories.trusted_count() == 0
      assert repo().aggregate(RememberRequest, :count) == 0
      assert repo().aggregate(Evidence, :count) == 0
    end

    test "independent requests retain request evidence without duplicating a typed source" do
      source = session_evidence("shared-source")

      assert {:ok, memory} =
               Memories.remember(
                 "shared typed",
                 direct_opts("shared-typed-one") ++ [evidence: [source]]
               )

      assert {:ok, ^memory} =
               Memories.remember(
                 "shared typed",
                 direct_opts("shared-typed-two") ++ [evidence: [source]]
               )

      assert repo().aggregate(RememberRequest, :count) == 2
      assert repo().aggregate(Evidence, :count) == 3

      assert Enum.frequencies_by(Memories.list_evidence(memory.id), & &1.source_type) == %{
               "request" => 2,
               "session" => 1
             }
    end

    test "an independent request with conflicting attributes for an attached source rolls back" do
      source = session_evidence("conflicting-shared-source")

      assert {:ok, memory} =
               Memories.remember(
                 "conflicting shared typed",
                 direct_opts("conflicting-shared-one") ++ [evidence: [source]]
               )

      conflicting = Map.put(source, :evidence_kind, "contradicts")

      assert {:error, :conflicting_evidence} =
               Memories.remember(
                 "conflicting shared typed",
                 direct_opts("conflicting-shared-two") ++ [evidence: [conflicting]]
               )

      assert repo().aggregate(RememberRequest, :count) == 1
      assert repo().aggregate(Evidence, :count) == 2
      assert {:ok, %{evidence_count: 1}} = Memories.trusted_verify(memory.id)
    end

    test "returns an ordered chain and counts derived from rows" do
      assert {:ok, memory} = Memories.remember("ordered", direct_opts("ordered-one"))
      Process.sleep(2)
      assert {:ok, ^memory} = Memories.remember("ordered", direct_opts("ordered-two"))

      assert {:ok, verification} = Memories.trusted_verify(memory.id)
      assert verification.evidence_count == 2
      assert verification.supporting_count == 2
      assert verification.access_count == 0
      assert verification.application_count == 0
      assert verification.contradictory_evidence_count == 0
      assert verification.contradiction_count == 0
      assert verification.source_diversity == 1
      assert Enum.map(verification.evidence, & &1.source_type) == ["request", "request"]
      assert Memories.list_evidence(memory.id) == verification.evidence
      assert verification.evidence == Enum.sort_by(verification.evidence, &{&1.created_at, &1.id})
    end

    test "keeps retrieval, application, and contradictory evidence counts distinct" do
      contradictory =
        "distinct-truth-signals"
        |> session_evidence(%{host_id: "host"})
        |> Map.put(:evidence_kind, "contradicts")

      assert {:ok, memory} =
               Memories.remember(
                 "distinct truth signals",
                 direct_opts("distinct-truth-signals") ++ [evidence: [contradictory]]
               )

      memory
      |> Ecto.Changeset.change(access_count: 7, application_count: 3)
      |> repo().update!()

      assert {:ok, verification} = Memories.trusted_verify(memory.id)
      assert verification.access_count == 7
      assert verification.application_count == 3
      assert verification.contradictory_evidence_count == 1
      assert verification.contradiction_relation_count == 0
      assert verification.contradiction_count == verification.contradictory_evidence_count
    end

    test "source diversity changes with session or agent inside one host partition" do
      assert {:ok, memory} = Memories.remember("diverse", direct_opts("diverse-one"))
      assert {:ok, ^memory} = Memories.remember("diverse", direct_opts("diverse-two"))

      assert {:ok, ^memory} =
               Memories.remember(
                 "diverse",
                 direct_opts("diverse-agent") |> Keyword.put(:agent_id, "agent-two")
               )

      assert {:ok, other_host_memory} =
               Memories.remember(
                 "diverse",
                 direct_opts("diverse-host") |> Keyword.put(:host_id, "host-two")
               )

      refute other_host_memory.id == memory.id

      assert {:ok, verification} = Memories.trusted_verify(memory.id)
      assert verification.evidence_count == 3
      assert verification.source_diversity == 2
    end

    test "request evidence distinguishes sessions before host and agent provenance" do
      first_opts = direct_opts("session-one") |> Keyword.put(:session_id, "session-one")
      second_opts = direct_opts("session-two") |> Keyword.put(:session_id, "session-two")

      same_session_opts =
        direct_opts("session-one-again") |> Keyword.put(:session_id, "session-one")

      assert {:ok, memory} = Memories.remember("session-attributed", first_opts)
      assert {:ok, ^memory} = Memories.remember("session-attributed", second_opts)
      assert {:ok, ^memory} = Memories.remember("session-attributed", same_session_opts)

      assert {:ok, verification} = Memories.trusted_verify(memory.id)
      assert verification.evidence_count == 3
      assert verification.source_diversity == 2

      assert Enum.map(verification.evidence, & &1.session_id) ==
               ["session-one", "session-two", "session-one"]
    end

    test "preserves not-found behavior" do
      assert {:error, :not_found} = Memories.trusted_verify(Ecto.UUID.generate())
    end
  end

  defp direct_opts(key) do
    [
      agent_id: "agent",
      host_id: "host",
      idempotency_scope: "direct",
      idempotency_key: key
    ]
  end

  defp session_evidence(source_session_id, overrides \\ %{}) do
    Map.merge(
      %{
        source_session_id: source_session_id,
        host_id: "source-host",
        agent_id: "source-agent",
        session_id: "derived-session",
        evidence_kind: "derives",
        support_score: 0.9,
        excerpt: "source excerpt"
      },
      overrides
    )
  end
end
