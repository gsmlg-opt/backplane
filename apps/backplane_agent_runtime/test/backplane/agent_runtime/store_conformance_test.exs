defmodule Backplane.AgentRuntime.StoreConformanceTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Kernel
  alias Backplane.AgentRuntime.Store
  alias Backplane.AgentRuntime.StoreConformance
  alias __MODULE__.{FailingIfCalledProvider, FileStore, SettledProvider}

  defmodule DurableStore do
    @behaviour Store

    @impl Store
    def mode, do: :durable

    @impl Store
    def capabilities do
      %{
        expected_revision: true,
        transition_events: true,
        outbox_intents: true,
        recovery_records: true,
        artifact_references: true,
        atomic_transition_outbox: true,
        incarnation_fencing: true
      }
    end

    @impl Store
    def new(_incarnation), do: Agent.start_link(fn -> %{records: %{}, fail_next?: false} end)

    @impl Store
    def load(context, run_id, _opts \\ []) do
      Agent.get(context, fn state ->
        case Map.fetch(state.records, run_id) do
          {:ok, snapshot} -> {:ok, snapshot}
          :error -> {:error, Error.new(:not_found, "run not found")}
        end
      end)
    end

    @impl Store
    def store(context, record, meta) do
      with {:ok, run, transition, effects} <- Kernel.execute(record, meta.command) do
        stage = %{
          run: run,
          revision: run.expected_revision,
          transition: transition,
          effects: effects,
          outbox: Map.get(meta, :outbox, []),
          incarnation: run.incarnation
        }

        acknowledge_commit(context, stage, meta)
        |> case do
          {:ok, result} -> {:ok, Map.put(result, :outbox, stage.outbox)}
          error -> error
        end
      end
    end

    @impl Store
    def acknowledge_commit(context, stage, _meta) do
      Agent.get_and_update(context, fn state ->
        cond do
          state.fail_next? ->
            {{:error, Error.new(:execution_failure, "injected commit failure")},
             %{state | fail_next?: false}}

          current_revision(state, stage.run.run_id) != stage.revision - 1 ->
            {{:error, Error.new(:resource_conflict, "revision conflict")}, state}

          true ->
            snapshot =
              Map.take(stage, [:run, :revision, :transition, :effects, :outbox, :incarnation])

            records = Map.put(state.records, stage.run.run_id, snapshot)
            {{:ok, %{revision: stage.revision}}, %{state | records: records}}
        end
      end)
    end

    @impl Store
    def fence(context, run_id, expected_revision, current_incarnation, next_incarnation) do
      Agent.get_and_update(context, fn state ->
        with {:ok, snapshot} <- Map.fetch(state.records, run_id),
             true <- snapshot.revision == expected_revision,
             true <- snapshot.run.incarnation == current_incarnation do
          revision = expected_revision + 1

          run =
            snapshot.run
            |> Map.put(:incarnation, next_incarnation)
            |> Map.put(:expected_revision, revision)

          snapshot = %{snapshot | run: run, revision: revision, incarnation: next_incarnation}
          result = {:ok, %{revision: revision, run: run}}
          {result, put_in(state, [:records, run_id], snapshot)}
        else
          _ -> {{:error, Error.new(:resource_conflict, "incarnation conflict")}, state}
        end
      end)
    end

    def restart(context), do: {:ok, context}
    def fail_next(context), do: Agent.update(context, &%{&1 | fail_next?: true})
    def dependent_effect_count(_context, _run_id), do: 0

    defp current_revision(state, run_id) do
      case Map.fetch(state.records, run_id) do
        {:ok, snapshot} -> snapshot.revision
        :error -> 0
      end
    end
  end

  test "runs the reusable durable adapter contract" do
    {:ok, context} = DurableStore.new(1)

    assert {:ok,
            %{
              mode: :durable,
              checks: [
                :atomic_commit,
                :direct_execution_commit,
                :failed_commit,
                :incarnation_fence,
                :outstanding_effect_reconstruction,
                :restart_reconstruction,
                :stale_revision,
                :terminal_reconstruction,
                :uncertain_effect_fencing
              ]
            }} =
             StoreConformance.run(DurableStore, context,
               run_id: "conformance_#{System.unique_integer([:positive])}",
               restart: &DurableStore.restart/1,
               fail_next_commit: &DurableStore.fail_next/1,
               dependent_effect_count: &DurableStore.dependent_effect_count/2
             )
  end

  @tag :tmp_dir
  test "runs against a file-backed adapter across a fresh context", %{tmp_dir: tmp_dir} do
    {:ok, context} = FileStore.open(tmp_dir)

    assert {:ok, %{mode: :durable}} =
             StoreConformance.run(FileStore, context,
               run_id: "disk_#{System.unique_integer([:positive])}",
               restart: &FileStore.restart/1,
               fail_next_commit: &FileStore.fail_next/1,
               dependent_effect_count: &FileStore.dependent_effect_count/2
             )
  end

  test "durable fencing rejects stale executors and advances the revision atomically" do
    {:ok, context} = DurableStore.new(1)
    run = base_run("fence_run")

    {:ok, staged} =
      Store.stage(DurableStore, context, run, %{
        command: {:admit, 10, %{state: :running}},
        incarnation: 1
      })

    assert {:ok, %{revision: 1}} =
             Store.acknowledge_commit(DurableStore, context, staged.stage, %{})

    assert {:ok, %{revision: 2, run: %{incarnation: 2, expected_revision: 2}}} =
             Store.fence(DurableStore, context, run.run_id, 1, 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             Store.fence(DurableStore, context, run.run_id, 1, 1, 3)
  end

  test "does not present ephemeral storage as durable conformance" do
    {:ok, context} = EphemeralStore.new(1)

    assert {:error, %Error{class: :unsupported_capability, message: "durable store required"}} =
             StoreConformance.run(EphemeralStore, context,
               run_id: "ephemeral",
               restart: fn context -> {:ok, context} end,
               fail_next_commit: fn _context -> :ok end,
               dependent_effect_count: fn _context, _run_id -> 0 end
             )
  end

  @tag :tmp_dir
  test "file-backed store restores a settled Conversation without dispatch", %{tmp_dir: tmp_dir} do
    {:ok, context} = FileStore.open(tmp_dir)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "conversation_restart",
        incarnation: 1,
        store: FileStore,
        context: context,
        provider: SettledProvider,
        provider_context: %{},
        subscriber: self(),
        work: 5,
        run_timeout: 1_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "persist")
    assert_receive {:agent_runtime, "conversation_restart", %{type: :run_completed}}, 1_000
    assert %{phase: :terminal, run: run} = Conversation.status(conversation)
    assert run.context.conversation.messages != []
    GenServer.stop(conversation)

    {:ok, restarted_context} = FileStore.restart(context)
    assert {:ok, %{run: persisted}} = FileStore.load(restarted_context, run.run_id, [])

    {:ok, restored} =
      Conversation.start_link(
        run_id: run.run_id,
        run: persisted,
        store: FileStore,
        context: restarted_context,
        provider: FailingIfCalledProvider,
        provider_context: %{test: self()},
        subscriber: self(),
        work: 5,
        run_timeout: 1_000
      )

    assert %{phase: :terminal, run: ^persisted} = Conversation.status(restored)
    refute_receive :provider_called, 20
    GenServer.stop(restored)
  end

  defp base_run(run_id) do
    %{
      run_id: run_id,
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end

  defmodule FileStore do
    @behaviour Store

    @impl Store
    def mode, do: :durable

    @impl Store
    def capabilities, do: DurableStore.capabilities()

    @impl Store
    def new(_incarnation),
      do: {:error, Error.new(:validation, "open/1 requires a fixture directory")}

    def open(root) do
      {:ok, faults} = Agent.start_link(fn -> false end)
      {:ok, %{root: root, faults: faults}}
    end

    def restart(%{root: root}), do: open(root)
    def fail_next(%{faults: faults}), do: Agent.update(faults, fn _ -> true end)
    def dependent_effect_count(_context, _run_id), do: 0

    @impl Store
    def load(context, run_id, _opts \\ []) do
      case File.read(path(context, run_id)) do
        {:ok, bytes} -> {:ok, :erlang.binary_to_term(bytes, [:safe])}
        {:error, :enoent} -> {:error, Error.new(:not_found, "run not found")}
        {:error, reason} -> {:error, Error.new(:execution_failure, "read failed", cause: reason)}
      end
    end

    @impl Store
    def store(context, record, meta) do
      with {:ok, run, transition, effects} <- Kernel.execute(record, meta.command) do
        stage = %{
          run: run,
          revision: run.expected_revision,
          transition: transition,
          effects: effects,
          outbox: Map.get(meta, :outbox, []),
          incarnation: run.incarnation
        }

        acknowledge_commit(context, stage, meta)
        |> case do
          {:ok, result} -> {:ok, Map.put(result, :outbox, stage.outbox)}
          error -> error
        end
      end
    end

    @impl Store
    def acknowledge_commit(context, stage, _meta) do
      if Agent.get_and_update(context.faults, fn fail? -> {fail?, false} end) do
        {:error, Error.new(:execution_failure, "injected commit failure")}
      else
        update(context, stage.run.run_id, fn current ->
          if revision(current) == stage.revision - 1 do
            snapshot =
              Map.take(stage, [:run, :revision, :transition, :effects, :outbox, :incarnation])

            {:ok, snapshot, %{revision: stage.revision}}
          else
            {:error, Error.new(:resource_conflict, "revision conflict")}
          end
        end)
      end
    end

    @impl Store
    def fence(context, run_id, expected_revision, current_incarnation, next_incarnation) do
      update(context, run_id, fn snapshot ->
        if revision(snapshot) == expected_revision and
             get_in(snapshot, [:run, :incarnation]) == current_incarnation do
          revision = expected_revision + 1

          run =
            snapshot.run
            |> Map.put(:incarnation, next_incarnation)
            |> Map.put(:expected_revision, revision)

          snapshot = %{snapshot | run: run, revision: revision, incarnation: next_incarnation}
          {:ok, snapshot, %{revision: revision, run: run}}
        else
          {:error, Error.new(:resource_conflict, "incarnation conflict")}
        end
      end)
    end

    defp update(context, run_id, callback) do
      path = path(context, run_id)

      :global.trans({__MODULE__, path}, fn ->
        current =
          case load(context, run_id, []) do
            {:ok, snapshot} -> snapshot
            {:error, %Error{class: :not_found}} -> nil
          end

        case callback.(current) do
          {:ok, snapshot, result} ->
            temp = path <> ".#{System.unique_integer([:positive])}.tmp"

            with :ok <- File.write(temp, :erlang.term_to_binary(snapshot), [:binary, :sync]),
                 :ok <- File.rename(temp, path) do
              {:ok, result}
            else
              {:error, reason} ->
                File.rm(temp)
                {:error, Error.new(:execution_failure, "write failed", cause: reason)}
            end

          {:error, %Error{} = error} ->
            {:error, error}
        end
      end)
    end

    defp path(context, run_id) do
      Path.join(context.root, Base.url_encode64(run_id, padding: false) <> ".term")
    end

    defp revision(nil), do: 0
    defp revision(snapshot), do: snapshot.revision
  end

  defmodule SettledProvider do
    def stream(_request, _context) do
      [
        %{
          type: :response_completed,
          message: %{role: :assistant, content: "persisted"}
        }
      ]
    end
  end

  defmodule FailingIfCalledProvider do
    def stream(_request, context) do
      send(context.test, :provider_called)
      []
    end
  end
end
