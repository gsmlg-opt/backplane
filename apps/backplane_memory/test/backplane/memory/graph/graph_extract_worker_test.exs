defmodule Backplane.Memory.Workers.GraphExtractWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Workers.GraphExtractWorker

  @partition %{
    host_id: "host-test",
    client_id: "host:host-test",
    scope: "global",
    namespace: "private"
  }

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
        Memories.remember("observation #{i} for session #{session_id}",
          agent_id: "agent-test",
          host_id: "host-test",
          client_id: "host:host-test",
          scope: "global",
          namespace: "private",
          session_id: session_id
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

    test "returns :skipped_min_observations for a session with zero memories" do
      session_id = Ecto.UUID.generate()

      result =
        GraphExtractWorker.perform(job(session_id))

      assert result == {:ok, :skipped_min_observations}
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

  defp job(session_id) do
    args =
      Map.new(@partition, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("session_id", session_id)

    %Oban.Job{args: args}
  end
end
