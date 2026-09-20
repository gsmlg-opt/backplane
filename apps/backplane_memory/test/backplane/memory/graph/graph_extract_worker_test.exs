defmodule Backplane.Memory.Workers.GraphExtractWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
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

  setup do
    Application.put_env(:backplane_memory, :llm_module, MockLLMEmpty)
    on_exit(fn -> Application.delete_env(:backplane_memory, :llm_module) end)
    :ok
  end

  defp make_memories(session_id, count) do
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
               GraphExtractWorker.perform(job(session_id))
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

  defp job(session_id) do
    args =
      "host-test"
      |> canonical_partition(client_id: "host:host-test", scope: "global")
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("session_id", session_id)

    %Oban.Job{args: args}
  end
end
