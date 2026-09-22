defmodule Backplane.Memory.Workers.GraphExtractWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Projections.{ProjectedSession, Source, State}
  alias Backplane.Memory.Workers.GraphExtractWorker
  alias Backplane.MemorySpaces.BackfillIssue

  defmodule MockLLMEmpty do
    def extract_graph(_observations), do: {:ok, %{nodes: [], edges: []}}
  end

  defmodule MockLLMWithData do
    def extract_graph(_observations) do
      {:ok,
       %{
         nodes: [
           %{type: "Concept", name: "test_concept"},
           %{type: "Module", name: "TestModule"}
         ],
         edges: []
       }}
    end
  end

  defmodule MockLLMError do
    def extract_graph(_observations), do: {:error, "llm unavailable"}
  end

  defmodule MockLLMSkip do
    def extract_graph(_observations), do: {:skip, :no_llm}
  end

  defmodule MockLLMRaise do
    def extract_graph(_observations), do: raise("graph exploded")
  end

  defmodule BlockingLLM do
    def extract_graph(_observations) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:graph_generation_blocked, self()})

      receive do
        :release_graph_generation ->
          {:ok, %{nodes: [%{type: "Concept", name: "stale_concept"}], edges: []}}
      end
    end
  end

  setup do
    Application.put_env(:backplane_memory, :llm_module, MockLLMEmpty)

    on_exit(fn ->
      Application.delete_env(:backplane_memory, :llm_module)
      :persistent_term.erase({BlockingLLM, :owner})
    end)

    :ok
  end

  defp make_memories(session_id, count) do
    partition =
      canonical_partition("host-test",
        client_id: "host:host-test",
        scope: "global",
        namespace: "private"
      )

    repo().insert!(%ProjectedSession{
      subject_id: Source.subject_id!("host-test", session_id),
      memory_space_id: partition.memory_space_id,
      host_id: "host-test",
      client_id: "host:host-test",
      source_client_id: "host:host-test",
      scope: "global",
      namespace: "private",
      session_id: session_id,
      status: "completed",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now(),
      last_event_at: DateTime.utc_now(),
      processing_version: "session-v1",
      input_revision: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    })

    for i <- 1..count do
      {:ok, _mem} =
        Memories.remember(
          "observation #{i} for session #{session_id}",
          canonical_memory_opts("host-test",
            agent_id: "agent-test",
            client_id: "host:host-test",
            scope: "global",
            namespace: "private",
            session_id: session_id
          )
        )
    end
  end

  describe "perform/1 — skips when below min_observations" do
    test "returns :skipped_min_observations when session has fewer than min_obs memories" do
      session_id = Ecto.UUID.generate()
      # Insert 2 memories; default min_obs is 3
      make_memories(session_id, 2)

      result =
        GraphExtractWorker.perform(job(session_id))

      assert result == {:ok, :skipped_min_observations}
    end

    test "fails closed when a session has no authoritative partition source" do
      session_id = Ecto.UUID.generate()

      result =
        GraphExtractWorker.perform(job(session_id))

      assert result == {:discard, :incomplete_partition}
    end
  end

  describe "perform/1 — calls LLM when obs >= min_observations" do
    test "delegates to LLM module and returns node/edge counts" do
      session_id = Ecto.UUID.generate()
      Application.put_env(:backplane_memory, :llm_module, MockLLMWithData)
      make_memories(session_id, 3)

      assert {:ok, %{nodes_extracted: 2, edges_extracted: 0}} =
               GraphExtractWorker.perform(job(session_id))
    end

    test "returns {:ok, {:skipped, reason}} when LLM returns :skip" do
      session_id = Ecto.UUID.generate()
      Application.put_env(:backplane_memory, :llm_module, MockLLMSkip)
      make_memories(session_id, 3)

      assert {:ok, {:skipped, :no_llm}} =
               GraphExtractWorker.perform(job(session_id))
    end

    test "returns {:error, reason} when LLM returns error so Oban retries" do
      session_id = Ecto.UUID.generate()
      Application.put_env(:backplane_memory, :llm_module, MockLLMError)
      make_memories(session_id, 3)

      assert {:error, "llm unavailable"} =
               GraphExtractWorker.perform(job(session_id, attempt: 1, max_attempts: 3))

      subject_id = Source.subject_id!("host-test", session_id)

      assert %State{status: "failed"} =
               repo().get_by!(State, projector: "graph", subject_id: subject_id)

      assert {:error, "llm unavailable"} =
               GraphExtractWorker.perform(job(session_id, attempt: 3, max_attempts: 3))

      assert %State{status: "dead_letter"} =
               repo().get_by!(State, projector: "graph", subject_id: subject_id)
    end

    test "records dead-letter before reraising an exception on the final attempt" do
      session_id = Ecto.UUID.generate()
      Application.put_env(:backplane_memory, :llm_module, MockLLMRaise)
      make_memories(session_id, 3)

      assert_raise RuntimeError, "graph exploded", fn ->
        GraphExtractWorker.perform(job(session_id, attempt: 3, max_attempts: 3))
      end

      assert %State{status: "dead_letter", last_error: "graph exploded"} =
               repo().get_by!(State,
                 projector: "graph",
                 subject_id: Source.subject_id!("host-test", session_id)
               )
    end

    test "a source revision advanced during generation rejects all stale graph writes" do
      session_id = Ecto.UUID.generate()
      make_memories(session_id, 3)
      :persistent_term.put({BlockingLLM, :owner}, self())
      Application.put_env(:backplane_memory, :llm_module, BlockingLLM)

      old_task = Task.async(fn -> GraphExtractWorker.perform(job(session_id)) end)
      Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), old_task.pid)
      old_task_pid = old_task.pid
      assert_receive {:graph_generation_blocked, ^old_task_pid}, 5_000

      new_revision = :crypto.hash(:sha256, "new graph revision") |> Base.encode16(case: :lower)

      repo().update_all(
        from(session in ProjectedSession, where: session.session_id == ^session_id),
        set: [input_revision: new_revision]
      )

      Application.put_env(:backplane_memory, :llm_module, MockLLMEmpty)

      assert {:ok, %{nodes_extracted: 0, edges_extracted: 0}} =
               GraphExtractWorker.perform(job(session_id))

      send(old_task.pid, :release_graph_generation)
      assert {:discard, :stale} = Task.await(old_task, 5_000)

      refute repo().exists?(from(node in Node, where: node.name == "stale_concept"))

      assert %State{status: "complete", input_revision: ^new_revision} =
               repo().get_by!(State,
                 projector: "graph",
                 subject_id: Source.subject_id!("host-test", session_id)
               )
    end
  end

  test "fails closed when generator provenance is incomplete" do
    partition = canonical_partition("graph-incomplete")

    for field <- [:memory_space_id, :host_id, :client_id, :scope, :namespace],
        invalid <- [nil, "", "   "] do
      incomplete = Map.put(partition, field, invalid)
      args = Map.new(incomplete, fn {key, value} -> {to_string(key), value} end)

      assert {:discard, :incomplete_partition} =
               GraphExtractWorker.perform(%Oban.Job{
                 args: Map.put(args, "session_id", "session")
               })

      assert {:error, :incomplete_partition} =
               GraphExtractWorker.enqueue("session", incomplete)
    end

    mismatched = Map.put(partition, "host_id", "other-host")
    mismatched_args = partition |> stringify_keys() |> Map.put(:host_id, "other-host")

    assert {:discard, :partition_mismatch} =
             GraphExtractWorker.perform(%Oban.Job{
               args: Map.put(mismatched_args, "session_id", "session")
             })

    assert {:error, :partition_mismatch} = GraphExtractWorker.enqueue("session", mismatched)

    assert repo().aggregate(
             from(i in BackfillIssue,
               where:
                 i.source_table == "memory_graph_generator" and
                   i.reason == "incomplete_partition" and i.disposition == "pending"
             ),
             :count
           ) >= 1
  end

  test "rejects complete claims that mismatch the authoritative session partition" do
    session_id = Ecto.UUID.generate()
    make_memories(session_id, 3)
    authoritative = canonical_partition("host-test", client_id: "host:host-test")

    for {field, wrong} <- [
          memory_space_id: canonical_partition("other-graph").memory_space_id,
          host_id: "other-host",
          client_id: "other-client",
          scope: "other-scope",
          namespace: "team:other"
        ] do
      claim = Map.put(authoritative, field, wrong)

      assert {:discard, :partition_mismatch} =
               GraphExtractWorker.perform(%Oban.Job{
                 args: claim |> stringify_keys() |> Map.put("session_id", session_id)
               })
    end

    refute_received {:graph_input, _}
  end

  test "failure issue identity and details ignore unrelated graph job arguments" do
    session_id = Ecto.UUID.generate()
    make_memories(session_id, 1)

    wrong =
      canonical_partition("host-test", client_id: "host:host-test")
      |> Map.put(:scope, "wrong-scope")
      |> stringify_keys()
      |> Map.put("session_id", session_id)

    assert {:discard, :partition_mismatch} =
             GraphExtractWorker.perform(%Oban.Job{args: wrong})

    [first] =
      repo().all(from(i in BackfillIssue, where: i.source_table == "memory_graph_generator"))

    assert {:discard, :partition_mismatch} =
             GraphExtractWorker.perform(%Oban.Job{
               args: Map.merge(wrong, %{"content" => "secret", "metadata" => %{"x" => 1}})
             })

    assert [%BackfillIssue{id: id, details: details}] =
             repo().all(
               from(i in BackfillIssue, where: i.source_table == "memory_graph_generator")
             )

    assert id == first.id

    assert Map.keys(details) |> Enum.sort() ==
             ~w(client_id host_id memory_space_id namespace scope session_id)

    refute inspect(details) =~ "secret"
  end

  defp stringify_keys(map),
    do:
      Map.new(map, fn {key, value} -> {if(is_atom(key), do: to_string(key), else: key), value} end)

  defp job(session_id, opts \\ []) do
    args =
      "host-test"
      |> canonical_partition(client_id: "host:host-test", scope: "global")
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("session_id", session_id)

    %Oban.Job{
      args: args,
      attempt: Keyword.get(opts, :attempt, 0),
      max_attempts: Keyword.get(opts, :max_attempts, 20)
    }
  end
end
