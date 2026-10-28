defmodule Backplane.AgentRuntime.StagedExportFileHostFixture do
  @moduledoc """
  Trusted-local, single-host fixture. The caller owns exclusive directory custody
  across OS processes; the cold runner enforces this with sequential subprocesses.
  One GenServer serializes all CAS operations. Each accepted mutation fsyncs a
  complete temporary snapshot and atomically renames it before acknowledging.
  This proves process restart persistence, not power-loss or multiwriter safety.
  Binary terms are decoded only from this fixture's trusted private directory.
  """
  use GenServer
  @behaviour Backplane.AgentRuntime.Store
  # Also structurally implements Reconciliation.Adapter; both behaviours declare
  # mode/0, so declaring both produces a compiler conflicting-behaviours warning.
  alias Backplane.AgentRuntime.{Error, Store}

  @impl true
  def mode, do: :durable
  @impl true
  def capabilities,
    do:
      Map.new(
        [
          :expected_revision,
          :transition_events,
          :outbox_intents,
          :atomic_transition_outbox,
          :recovery_records,
          :artifact_references,
          :incarnation_fencing
        ],
        &{&1, true}
      )

  @impl true
  def new(_),
    do: {:error, Error.new(:validation, "use open/1 with an exclusively owned fixture directory")}

  def open(dir) do
    dir = Path.expand(dir)
    File.mkdir_p!(dir)
    GenServer.start(__MODULE__, dir, name: {:global, {__MODULE__, dir}})
  end

  def config(context), do: {__MODULE__, context}

  def cleanup(context) do
    if Process.alive?(context), do: GenServer.stop(context)
    :ok
  end

  def put(context, key, value), do: GenServer.call(context, {:put, key, value})
  def get(context, key), do: GenServer.call(context, {:get, key})
  def load_evidence(context, ref), do: get(context, {:evidence, ref})
  def load_receipt(context, ref), do: get(context, {:receipt, ref})
  def runtime_store(context, "source-store"), do: {:ok, {__MODULE__, context}}
  def runtime_store(_, _), do: missing()

  def load_recovery_journal(context, ref) do
    with {:ok, record} <- load(context, ref["run_id"]) do
      entries =
        Enum.map(record.journal, fn
          %{revision: revision, fence: fence} ->
            %{
              "revision" => revision,
              "prior_revision" => fence.from_revision,
              "prior_incarnation" => fence.from_incarnation,
              "incarnation" => fence.to_incarnation,
              "kind" => "fence",
              "input" => %{}
            }

          %{revision: revision, command: command, incarnation: incarnation} ->
            [kind, _at | rest] = Tuple.to_list(command)

            input =
              case rest do
                [input] -> input
                [] -> %{}
              end

            {:ok, input} = Backplane.AgentRuntime.Codex.Reconciliation.Evidence.public(input)

            %{
              "revision" => revision,
              "prior_revision" => revision - 1,
              "prior_incarnation" => incarnation,
              "incarnation" => incarnation,
              "kind" => to_string(kind),
              "input" => input
            }
        end)

      {:ok, entries}
    end
  end

  @impl true
  def load(context, id, _opts \\ []), do: get(context, {:run, id})

  def fault_next(context, phase, fault) when fault in [:refuse, :lose_ack],
    do: GenServer.call(context, {:fault, phase, fault})

  def compare_and_swap_receipt(context, id, expected, next),
    do: GenServer.call(context, {:receipt, id, expected, next})

  @impl true
  def fence(context, id, expected, current, next),
    do: GenServer.call(context, {:fence, id, expected, current, next})

  @impl true
  def store(context, run, meta) do
    with {:ok, %{stage: stage}} <- Store.stage(__MODULE__, context, run, meta),
         do: acknowledge_commit(context, stage, meta)
  end

  @impl true
  def acknowledge_commit(context, stage, meta),
    do: GenServer.call(context, {:commit, Map.put(stage, :command, meta.command)})

  @impl GenServer
  def init(dir) do
    path = Path.join(dir, "host.term")
    data = if File.exists?(path), do: :erlang.binary_to_term(File.read!(path)), else: %{}
    {:ok, %{path: path, data: data, faults: %{}}}
  end

  @impl GenServer
  def handle_call({:get, key}, _, state),
    do: {:reply, Map.fetch(state.data, key) |> fetched(), state}

  def handle_call({:fault, phase, fault}, _, state),
    do: {:reply, :ok, put_in(state, [:faults, phase], fault)}

  def handle_call({:put, key, value}, _, state) do
    case Map.fetch(state.data, key) do
      {:ok, ^value} -> {:reply, :ok, state}
      {:ok, _} -> {:reply, conflict(), state}
      :error -> persist(state, key, value, :evidence, :ok)
    end
  end

  def handle_call({:commit, stage}, _, state) do
    run = stage.run
    expected = stage.revision - 1
    old = state.data[{:run, run.run_id}]

    valid =
      if old,
        do: old.revision == expected and old.run.incarnation == stage.incarnation,
        else: expected == 0

    if valid do
      record = %{
        run: run,
        revision: stage.revision,
        effects: stage.effects,
        outbox: stage.outbox,
        journal:
          if(old, do: old.journal, else: []) ++
            [
              %{
                revision: stage.revision,
                transition: stage.transition,
                command: stage.command,
                incarnation: stage.incarnation,
                effects: stage.effects,
                outbox: stage.outbox
              }
            ]
      }

      phase =
        case hd(stage.transition.events).type do
          "run.conversation_updated" -> :usage
          type when type in ["run.completed", "run.failed"] -> :finish
          type -> type
        end

      persist(
        state,
        {:run, run.run_id},
        record,
        phase,
        {:ok, %{revision: stage.revision, outbox: stage.outbox}}
      )
    else
      {:reply, conflict(), state}
    end
  end

  def handle_call({:fence, id, expected, current, next}, _, state) do
    case state.data[{:run, id}] do
      %{revision: ^expected, run: %{incarnation: ^current} = run} = old when next > current ->
        revision = expected + 1
        run = %{run | incarnation: next, expected_revision: revision}

        entry = %{
          revision: revision,
          fence: %{
            from_incarnation: current,
            to_incarnation: next,
            from_revision: expected,
            to_revision: revision
          }
        }

        record = %{old | run: run, revision: revision, journal: old.journal ++ [entry]}
        persist(state, {:run, id}, record, :fence, {:ok, %{revision: revision, run: run}})

      _ ->
        {:reply, conflict(), state}
    end
  end

  def handle_call({:receipt, id, expected, next}, _, state) do
    old = state.data[{:receipt, id}]

    valid =
      next["receipt_id"] == id and next["revision"] == expected + 1 and
        if(old,
          do:
            old["revision"] == expected and old["subject"] == next["subject"] and
              old["manifest_digest"] == next["manifest_digest"],
          else: expected == 0
        )

    cond do
      old == next -> {:reply, {:ok, old}, state}
      valid -> persist(state, {:receipt, id}, next, :receipt, {:ok, next})
      true -> {:reply, conflict(), state}
    end
  end

  defp persist(state, key, value, phase, reply) do
    {fault, faults} = Map.pop(state.faults, phase)
    state = %{state | faults: faults}

    if fault == :refuse do
      {:reply,
       {:error,
        Error.new(:unknown_outcome, "fixture definite write refusal",
          details: %{committed: false, phase: phase}
        )}, state}
    else
      data = Map.put(state.data, key, value)
      tmp = state.path <> ".next"
      {:ok, file} = :file.open(String.to_charlist(tmp), [:write, :binary, :raw])
      :ok = :file.write(file, :erlang.term_to_binary(data))
      :ok = :file.sync(file)
      :ok = :file.close(file)
      :ok = File.rename(tmp, state.path)

      reply =
        if fault == :lose_ack,
          do:
            {:error,
             Error.new(:unknown_outcome, "fixture committed write lost acknowledgement",
               details: %{committed: true, phase: phase}
             )},
          else: reply

      {:reply, reply, %{state | data: data}}
    end
  end

  defp fetched({:ok, value}), do: {:ok, value}
  defp fetched(:error), do: missing()
  defp missing, do: {:error, Error.new(:not_found, "fixture durable record absent")}
  defp conflict, do: {:error, Error.new(:resource_conflict, "fixture durable CAS conflict")}
end
