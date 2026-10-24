defmodule Backplane.Memory.Recall.RetrieverTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.Recall.{Candidate, QueryPlan, Retriever}

  @partition %{
    memory_space_id: "00000000-0000-4000-8000-000000000099",
    host_id: "h",
    client_id: "c",
    scope: "s",
    namespace: "n"
  }

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: unique_supervisor()})
    previous = Application.get_env(:backplane_memory, :recall_task_supervisor)
    Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_memory, :recall_task_supervisor, previous),
        else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
    end)
  end

  test "channels start concurrently and the slowest channel bounds wall latency" do
    owner = self()

    provider = fn channel ->
      fn _plan, _limit ->
        send(owner, {:started, channel, self()})
        receive do: (:release -> {:ok, []})
      end
    end

    task =
      Task.async(fn ->
        Retriever.retrieve(plan(),
          channel_fns: %{
            fts: provider.(:fts),
            vector: provider.(:vector),
            graph: provider.(:graph)
          },
          timeout_ms: 500
        )
      end)

    pids = for _ <- 1..3, into: [], do: receive(do: ({:started, channel, pid} -> {channel, pid}))
    assert Enum.sort(Enum.map(pids, &elem(&1, 0))) == [:fts, :graph, :vector]
    Enum.each(pids, fn {_channel, pid} -> send(pid, :release) end)
    assert {:ok, %{fused: [], channels: channels}} = Task.await(task)
    assert Enum.all?(channels, fn {_channel, outcome} -> outcome.status == :ok end)
  end

  test "the default budget admits a successful provider slower than one second" do
    wanted = candidate()

    assert {:ok, result} =
             Retriever.retrieve(plan(),
               channel_fns: %{
                 fts: fn _, _ -> {:ok, []} end,
                 graph: fn _, _ -> {:unavailable, :no_entities} end,
                 vector: fn _, _ ->
                   Process.sleep(1_200)
                   {:ok, [{wanted, 0.9}]}
                 end
               }
             )

    assert result.channels.vector.status == :ok
    assert [%{candidate: ^wanted}] = result.fused
    assert result.trace.channel_availability["vector"]
  end

  test "a later vector snapshot preserves a lexical match across timestamp-only revision drift" do
    owner = self()
    older = %{candidate() | current_context: %{revision: 100}}
    newer = %{older | current_context: %{revision: 200}}

    task =
      Task.async(fn ->
        Retriever.retrieve(plan(),
          channel_fns: %{
            fts: fn _, _ ->
              send(owner, :lexical_snapshot_read)
              {:ok, [{older, 0.8}]}
            end,
            vector: fn _, _ ->
              send(owner, {:vector_waiting, self()})
              receive do: (:release -> {:ok, [{newer, 0.9}]})
            end,
            graph: fn _, _ -> {:unavailable, :no_entities} end
          }
        )
      end)

    assert_receive :lexical_snapshot_read, 1_000
    assert_receive {:vector_waiting, vector}, 1_000
    send(vector, :release)

    assert {:ok, result} = Task.await(task)
    assert [%{candidate: ^newer, ranks: %{fts: 1, vector: 1}}] = result.fused
    assert result.channels.fts.status == :ok
    assert result.channels.vector.status == :ok
  end

  test "an explicit bounded timeout terminates the slow channel without losing lexical results" do
    owner = self()
    wanted = candidate()
    started = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Retriever.retrieve(plan(),
               timeout_ms: 30,
               channel_fns: %{
                 fts: fn _, _ -> {:ok, [{wanted, 0.8}]} end,
                 graph: fn _, _ -> {:unavailable, :no_entities} end,
                 vector: fn _, _ ->
                   send(owner, {:vector_pid, self()})
                   Process.sleep(:infinity)
                 end
               }
             )

    assert_receive {:vector_pid, pid}
    refute Process.alive?(pid)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert result.channels.vector.status == :timeout
    assert result.trace.channel_errors["vector"] == "timeout"
    assert [%{candidate: ^wanted}] = result.fused
  end

  test "errors, exits, and timeouts are isolated while FTS remains usable" do
    fts_candidate = candidate()

    assert {:ok, result} =
             Retriever.retrieve(plan(),
               channel_fns: %{
                 fts: fn _, _ -> {:ok, [{fts_candidate, 0.8}]} end,
                 vector: fn _, _ -> exit(:provider_down) end,
                 graph: fn _, _ ->
                   Process.sleep(100)
                   {:ok, []}
                 end
               },
               timeout_ms: 20
             )

    assert [%{candidate: ^fts_candidate}] = result.fused
    assert result.channels.fts.status == :ok
    assert result.channels.vector.status == :error
    assert result.channels.graph.status == :timeout
    assert result.channels.vector.error == "channel_exit"
    assert result.channels.graph.error == "timeout"
  end

  test "zero-weight channels are cleanly unavailable and output is trace-ready" do
    {:ok, plan} =
      QueryPlan.new(
        Map.merge(@partition, %{query: "q", channel_weights: %{fts: 1, vector: 0, graph: 0}})
      )

    assert {:ok, result} =
             Retriever.retrieve(plan,
               channel_fns: %{fts: fn _, _ -> {:ok, [{candidate(), 1.0}]} end}
             )

    assert result.channels.vector.status == :unavailable
    assert result.channels.graph.status == :unavailable
    assert [%{ranks: %{fts: 1}, scores: %{fts: 1.0, rrf: _}}] = result.fused

    assert %{"fts" => true, "vector" => false, "graph" => false} =
             result.trace.channel_availability
  end

  test "temporary task supervision loss degrades channels without crashing recall" do
    Application.put_env(:backplane_memory, :recall_task_supervisor, :missing_recall_supervisor)

    assert {:ok, %{fused: [], channels: channels}} = Retriever.retrieve(plan())
    assert Enum.all?(channels, fn {_channel, outcome} -> outcome.status == :unavailable end)
  end

  test "arbitrary provider errors collapse to privacy-safe closed classes" do
    assert {:ok, result} =
             Retriever.retrieve(plan(),
               channel_fns: %{
                 fts: fn _, _ -> {:ok, []} end,
                 vector: fn _, _ -> {:error, {:provider, %{token: "do-not-store"}}} end,
                 graph: fn _, _ -> {:unavailable, {:no_entities, "do-not-store"}} end
               }
             )

    assert result.channels.vector.error == "provider_error"
    assert result.channels.graph.error == "unavailable"
    refute inspect(result.trace) =~ "do-not-store"
  end

  test "an untrappable channel kill cannot kill the retrieval caller" do
    assert {:ok, result} =
             Retriever.retrieve(plan(),
               channel_fns: %{
                 fts: fn _, _ -> {:ok, [{candidate(), 1.0}]} end,
                 vector: fn _, _ -> Process.exit(self(), :kill) end,
                 graph: fn _, _ -> {:ok, []} end
               }
             )

    assert length(result.fused) == 1
    assert result.channels.vector.status == :error
    assert Process.alive?(self())
  end

  test "options are a closed unique keyword contract" do
    for opts <- [[1], [timeout_ms: 10, timeout_ms: 20], [timeout_mz: 10]] do
      assert {:error, :invalid_options} = Retriever.retrieve(plan(), opts)
    end
  end

  defp plan do
    {:ok, plan} = QueryPlan.new(Map.merge(@partition, %{query: "q", entity_hints: ["Backplane"]}))
    plan
  end

  defp candidate do
    id = Ecto.UUID.generate()

    {:ok, candidate} =
      Candidate.new(
        Map.merge(@partition, %{
          id: id,
          kind: :memory,
          memory_type: :semantic,
          content: "q",
          source_ids: [id]
        })
      )

    candidate
  end

  defp unique_supervisor,
    do: String.to_atom("retriever_test_supervisor_#{System.unique_integer([:positive])}")
end
