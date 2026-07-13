defmodule Backplane.Memory.ServiceTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.{Memories, Observations, Service}
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Workers.ProfileBuildWorker

  describe "tools/0" do
    test "exposes memory::* tools with handler functions" do
      names = Enum.map(Service.tools(), & &1.name)

      assert "memory::remember" in names
      assert "memory::recall" in names
      assert "memory::list" in names
      assert "memory::forget" in names
      assert "memory::stats" in names

      for tool <- Service.tools() do
        assert is_function(tool.handler, 1)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
      end
    end

    test "prefix is \"memory\"", do: assert(Service.prefix() == "memory")
  end

  describe "handle_remember/1" do
    test "persists a memory and returns id, scope, memory_type" do
      args = %{
        "content" => "London is in the UK.",
        "agent_id" => "a",
        "host_id" => "h",
        "scope" => "geo"
      }

      assert {:ok, %{id: id, scope: "geo", memory_type: "semantic"}} =
               Service.handle_remember(args)

      assert is_binary(id)
    end

    test "applies the documented semantic and global defaults" do
      assert {:ok, %{id: id, scope: "global", memory_type: "semantic"}} =
               Service.handle_remember(%{
                 "content" => "default contract",
                 "agent_id" => "default-agent",
                 "host_id" => "default-host"
               })

      assert {:ok, memory} = Memories.get(id)
      assert memory.scope == "global"
      assert memory.memory_type == "semantic"
    end

    test "returns changeset error when required fields are missing" do
      assert {:error, msg} = Service.handle_remember(%{"content" => "x"})
      assert msg =~ "agent_id" or msg =~ "host_id"
    end

    test "returns descriptive error when content is missing" do
      assert {:error, _} = Service.handle_remember(%{"agent_id" => "a"})
    end
  end

  describe "handle_recall/1" do
    test "falls back to text search when embedding is not configured" do
      {:ok, mem} =
        Memories.remember("service recall fallback",
          agent_id: "a",
          host_id: "h",
          scope: "service"
        )

      assert {:ok, %{results: [%{id: id}]}} =
               Service.handle_recall(%{
                 "query" => "service recall",
                 "limit" => 5,
                 "scope" => "service"
               })

      assert id == mem.id
    end

    test "returns an empty result set when no lexical memory matches" do
      assert {:ok, %{results: []}} =
               Service.handle_recall(%{"query" => "no-such-recall-contract-term"})
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
               Service.handle_recall(%{
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
               Service.handle_recall(%{
                 "query" => "default recall contract",
                 "scope" => scope
               })

      assert length(results) == 10
    end

    test "returns error when query is missing" do
      assert {:error, _} = Service.handle_recall(%{})
    end
  end

  describe "handle_list/1" do
    test "returns memories with id, content, scope" do
      {:ok, _} = Memories.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h")

      assert {:ok, %{results: [%{id: _, content: _, scope: _}]}} =
               Service.handle_list(%{"q" => "Tokyo"})
    end

    test "returns an empty result set when filters do not match" do
      assert {:ok, %{results: []}} =
               Service.handle_list(%{"scope" => "missing-list-contract-scope"})
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
               Service.handle_list(%{
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

      assert {:ok, %{results: results}} = Service.handle_list(%{"scope" => scope})

      expected_ids = entries |> Enum.reverse() |> Enum.take(50) |> Enum.map(&elem(&1, 0))
      assert Enum.map(results, & &1.id) == expected_ids
    end
  end

  describe "handle_forget/1" do
    test "soft-deletes a memory" do
      {:ok, mem} = Memories.remember("Berlin is in Germany.", agent_id: "a", host_id: "h")
      assert {:ok, %{id: id, status: "deleted"}} = Service.handle_forget(%{"id" => mem.id})
      assert id == mem.id
      assert {:error, :not_found} = Memories.get(mem.id)
    end

    test "returns error for unknown id" do
      assert {:error, "memory not found"} =
               Service.handle_forget(%{"id" => Ecto.UUID.generate()})
    end

    test "returns an error when id is missing" do
      assert {:error, "id is required and must be a string"} = Service.handle_forget(%{})
    end
  end

  describe "handle_stats/1" do
    test "returns an empty collection when there are no memories" do
      assert {:ok, %{stats: []}} = Service.handle_stats(%{})
    end

    test "returns stats grouped by memory_type" do
      {:ok, _} = Memories.remember("s1", agent_id: "a", host_id: "h", type: "semantic")
      assert {:ok, %{stats: stats}} = Service.handle_stats(%{})
      assert Enum.any?(stats, &(&1.memory_type == "semantic"))
    end
  end

  describe "handle_profile/1" do
    test "returns building for a missing profile and the cached profile afterward" do
      project = "profile-contract-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: "building"}} = Service.handle_profile(%{"project" => project})

      assert {:ok,
              %{
                project: ^project,
                top_concepts: %{},
                top_files: %{},
                patterns: %{},
                session_count: 0,
                total_observations: 0
              }} = Service.handle_profile(%{"project" => project})
    end

    test "returns an error when project is missing" do
      assert {:error, "project is required"} = Service.handle_profile(%{})
    end
  end

  describe "handle_file_history/1" do
    test "returns matching observations and honors exclude_session" do
      {:ok, _} = Observations.record("file-history-mine", "changed lib/contract.ex")
      {:ok, other} = Observations.record("file-history-other", "updated lib/contract.ex")

      assert {:ok, %{results: [%{id: id, session_id: "file-history-other"}]}} =
               Service.handle_file_history(%{
                 "files" => ["lib/contract.ex"],
                 "exclude_session" => "file-history-mine",
                 "limit" => 1
               })

      assert id == other.id
    end

    test "returns an empty result set for unmatched files" do
      assert {:ok, %{results: []}} =
               Service.handle_file_history(%{"files" => ["missing/contract.ex"]})
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

      assert {:ok, %{results: results}} = Service.handle_file_history(%{"files" => [path]})

      expected_ids = entries |> Enum.reverse() |> Enum.take(50) |> Enum.map(&elem(&1, 0))
      assert Enum.map(results, & &1.id) == expected_ids
    end

    test "returns an error when files is missing" do
      assert {:error, "files is required and must be an array"} =
               Service.handle_file_history(%{})
    end
  end

  describe "handle_sessions/1" do
    test "returns an empty result set when no sessions exist" do
      assert {:ok, %{sessions: []}} = Service.handle_sessions(%{})
    end

    test "applies the project filter" do
      {:ok, target} = Observations.register_session("session-contract-target", "project-a")
      {:ok, _decoy} = Observations.register_session("session-contract-decoy", "project-b")

      assert {:ok, %{sessions: [%{session_id: id, project: "project-a"}]}} =
               Service.handle_sessions(%{"project" => "project-a"})

      assert id == target.session_id
    end

    test "defaults to the newest 20 sessions" do
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

      assert {:ok, %{sessions: sessions}} = Service.handle_sessions(%{"project" => project})

      expected_ids = entries |> Enum.reverse() |> Enum.take(20) |> Enum.map(&elem(&1, 0))
      assert Enum.map(sessions, & &1.session_id) == expected_ids
    end
  end

  describe "handle_timeline/1" do
    test "returns an empty timeline when there are no observations" do
      assert {:ok, %{timeline: []}} = Service.handle_timeline(%{})
    end

    test "filters by session and does not impose a group order contract" do
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

      assert {:ok,
              %{
                timeline: [
                  %{session_id: "timeline-a", observations: observations}
                ]
              }} = Service.handle_timeline(%{"session_id" => "timeline-a"})

      assert Enum.map(observations, & &1.id) == [first_id, second_id]

      assert {:ok, %{timeline: grouped}} = Service.handle_timeline(%{})

      assert grouped |> Enum.map(& &1.session_id) |> MapSet.new() ==
               MapSet.new(["timeline-a", "timeline-b"])
    end

    test "defaults to the first 50 observations in chronological order" do
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

      assert {:ok, %{timeline: [%{observations: observations}]}} =
               Service.handle_timeline(%{"session_id" => session_id})

      expected_ids = entries |> Enum.take(50) |> Enum.map(&elem(&1, 0))
      assert Enum.map(observations, & &1.id) == expected_ids
    end
  end

  describe "handle_consolidate/1" do
    test "queues using session_id as the worker argument without validating the session" do
      missing_session = "missing-session-#{System.unique_integer([:positive])}"

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{status: "queued", session_id: ^missing_session}} =
                 Service.handle_consolidate(%{"session_id" => missing_session})

        assert Oban.Testing.assert_enqueued(
                 repo(),
                 worker: ProfileBuildWorker,
                 args: %{"project" => missing_session}
               )
      end)
    end

    test "returns an error when session_id is missing" do
      assert {:error, "session_id is required"} = Service.handle_consolidate(%{})
    end
  end

  describe "enabled?/0" do
    test "false by default (opt-in via services.memory.enabled)" do
      refute Service.enabled?()
    end
  end
end
