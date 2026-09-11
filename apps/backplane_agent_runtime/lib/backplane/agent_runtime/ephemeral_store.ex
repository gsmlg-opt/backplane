defmodule Backplane.AgentRuntime.EphemeralStore do
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Kernel

  @moduledoc """
  In-memory runtime store for tests and transient embedded runs.

  State and acknowledgements are held in process memory. A host restart loses
  both. This implementation is explicitly ephemeral and must not be presented
  as a durable store.
  """

  @behaviour Backplane.AgentRuntime.Store
  @impl Backplane.AgentRuntime.Store
  def mode, do: :ephemeral

  @impl Backplane.AgentRuntime.Store
  def capabilities do
    %{
      expected_revision: true,
      transition_events: true,
      outbox_intents: true,
      restart_loss: true,
      artifact_references: false,
      recovery_records: false
    }
  end

  @impl Backplane.AgentRuntime.Store
  def new(incarnation) when is_integer(incarnation) and incarnation >= 0 do
    {:ok, :ets.new(__MODULE__, [:set, :public, read_concurrency: true])}
  end

  @impl Backplane.AgentRuntime.Store
  def load(table, run_id, _opts \\ []) do
    case :ets.lookup(table, run_id) do
      [{^run_id, record}] -> {:ok, Map.put(record, :ephemeral, true)}
      [] -> {:error, Error.new(:not_found, "ephemeral run not found")}
    end
  end

  @impl Backplane.AgentRuntime.Store
  def store(table, record, meta) do
    with {:ok, run, transition, effects} <- Kernel.execute(record, meta.command),
         {:ok, expected} <- expected_revision(record),
         {:ok, committed} <- compare_and_swap(table, run, expected, transition, effects) do
      {:ok, %{revision: committed, outbox: Map.get(meta, :outbox, []), transition: transition}}
    end
  end

  @impl Backplane.AgentRuntime.Store
  def acknowledge_commit(table, stage, _meta) do
    run = Map.get(stage, :run)
    revision = Map.get(stage, :revision)
    effects = Map.get(stage, :effects)

    if is_map(run) and is_integer(revision) do
      :ets.insert(table, {run.run_id, %{run: run, revision: revision, effects: effects}})
      {:ok, %{revision: revision}}
    else
      {:error, Error.new(:validation, "invalid stage")}
    end
  end

  defp compare_and_swap(table, run, expected, _transition, effects) do
    new_revision = expected + 1

    case :ets.lookup(table, run.run_id) do
      [] ->
        insert(table, run, new_revision, effects)
        {:ok, new_revision}

      [{run_id, current}] when current.revision == expected ->
        insert(table, run_id, new_revision, effects)
        {:ok, new_revision}

      [{_run_id, current}] ->
        {:error,
         Error.new(:resource_conflict, "ephemeral revision conflict",
           details: %{expected: expected, current: current.revision}
         )}
    end
  end

  defp insert(table, run, revision, effects) do
    :ets.insert(table, {run.run_id, %{run: run, revision: revision, effects: effects}})
  end

  defp expected_revision(%{expected_revision: revision})
       when is_integer(revision) and revision >= 0,
       do: {:ok, revision}

  defp expected_revision(_record) do
    {:error, Error.new(:validation, "record expected_revision is required")}
  end
end
