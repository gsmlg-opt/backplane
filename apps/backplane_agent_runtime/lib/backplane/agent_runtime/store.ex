defmodule Backplane.AgentRuntime.Store do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Runtime storage contract for versioned run transitions.

  A record is accepted only when its expected revision is the currently
  committed revision. A successful commit returns the next revision and outbox
  intents. Hosts must execute effects only after that acknowledgement.
  """

  @callback mode() :: :ephemeral | :durable

  @callback capabilities() :: map()

  @callback load(term(), term(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback new(non_neg_integer()) :: {:ok, term()}

  @callback store(term(), map(), map()) ::
              {:ok, %{revision: non_neg_integer(), outbox: list()}} | {:error, Error.t()}

  @callback acknowledge_commit(term(), map(), map()) ::
              {:ok, %{revision: non_neg_integer()}} | {:error, Error.t()}

  @spec stage(module(), term(), map(), map()) ::
          {:ok, %{revision: non_neg_integer(), outbox: list(), stage: term()}}
          | {:error, Error.t()}
  def stage(impl, _context, record, meta)
      when is_atom(impl) and is_map(record) and is_map(meta) do
    with {:ok, mode} <- validate_mode(impl),
         {:ok, _capabilities} <- validate_capabilities(impl),
         {:ok, revision} <- expected_revision(record),
         {:ok, run, transition, effects} <-
           Backplane.AgentRuntime.Kernel.execute(record, meta.command) do
      stage = %{
        run: run,
        transition: transition,
        effects: effects,
        outbox: Map.get(meta, :outbox, []),
        incarnation: Map.get(meta, :incarnation, 0),
        revision: revision + 1
      }

      {:ok,
       %{revision: revision + 1, outbox: Map.get(meta, :outbox, []), stage: stage, mode: mode}}
    end
  end

  @spec acknowledge_commit(module(), term(), term(), map()) ::
          {:ok, %{revision: non_neg_integer(), outbox: list()}} | {:error, Error.t()}
  def acknowledge_commit(impl, context, stage, meta)
      when is_atom(impl) and is_map(stage) and is_map(meta) do
    with {:ok, mode} <- validate_mode(impl),
         {:ok, _capabilities} <- validate_capabilities(impl),
         {:ok, stage_revision} <- validate_stage_revision(stage),
         %{revision: revision} <- impl.acknowledge_commit(context, stage, meta) do
      if mode == :durable or stage_revision == revision do
        {:ok, %{revision: revision, outbox: Map.get(stage, :outbox, []), mode: mode}}
      else
        {:error, Error.new(:resource_conflict, "invalid stage revision")}
      end
    end
  end

  defp validate_stage_revision(stage) do
    case Map.get(stage, :revision) do
      revision when is_integer(revision) and revision >= 0 -> {:ok, revision}
      _ -> {:error, Error.new(:validation, "invalid stage revision")}
    end
  end

  @spec store(module(), term(), map(), map()) ::
          {:ok, %{revision: non_neg_integer(), outbox: list()}} | {:error, Error.t()}
  def store(impl, context, record, meta)
      when is_atom(impl) and is_map(record) and is_map(meta) do
    with {:ok, mode} <- validate_mode(impl),
         {:ok, _capabilities} <- validate_capabilities(impl),
         {:ok, revision} <- expected_revision(record) do
      case impl.store(context, record, meta) do
        {:ok, %{revision: committed_revision} = result}
        when is_integer(committed_revision) and committed_revision > revision ->
          {:ok, Map.put(result, :mode, mode)}

        {:ok, result} ->
          {:error,
           Error.new(:resource_conflict, "store returned an invalid revision",
             details: %{expected: revision + 1, received: Map.get(result, :revision)}
           )}

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error,
           Error.new(:execution_failure, "store returned an invalid acknowledgement",
             details: %{received: other}
           )}
      end
    end
  end

  @spec validate_mode(module()) :: {:ok, atom()} | {:error, Error.t()}
  def validate_mode(impl) when is_atom(impl) do
    case impl.mode() do
      mode when mode in [:ephemeral, :durable] ->
        {:ok, mode}

      other ->
        {:error,
         Error.new(:unsupported_capability, "invalid store mode", details: %{received: other})}
    end
  end

  @spec validate_capabilities(module()) :: {:ok, map()} | {:error, Error.t()}
  def validate_capabilities(impl) when is_atom(impl) do
    capabilities = impl.capabilities()

    if is_map(capabilities) and Map.has_key?(capabilities, :expected_revision) and
         Map.has_key?(capabilities, :transition_events) and
         Map.has_key?(capabilities, :outbox_intents) do
      {:ok, capabilities}
    else
      {:error,
       Error.new(
         :unsupported_capability,
         "store must declare expected_revision, transition_events, and outbox_intents"
       )}
    end
  end

  defp expected_revision(%{expected_revision: revision})
       when is_integer(revision) and revision >= 0,
       do: {:ok, revision}

  defp expected_revision(_record) do
    {:error, Error.new(:validation, "record expected_revision is required")}
  end
end
