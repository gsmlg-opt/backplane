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
         {:ok, _capabilities} <- validate_durable_or_ephemeral_capabilities(impl),
         {:ok, stage_revision} <- validate_stage(stage) do
      validate_staged_acknowledgement(
        impl.acknowledge_commit(context, stage, meta),
        stage_revision,
        stage,
        mode
      )
    end
  end

  defp validate_stage(stage) do
    run = Map.get(stage, :run)
    revision = Map.get(stage, :revision)

    if is_map(run) and not is_nil(Map.get(run, :run_id)) and is_integer(revision) and
         revision > 0 and Map.get(run, :expected_revision) == revision and
         is_map(Map.get(stage, :transition)) and is_list(Map.get(stage, :effects)) and
         is_list(Map.get(stage, :outbox)) do
      {:ok, revision}
    else
      {:error, Error.new(:validation, "invalid stage")}
    end
  end

  defp validate_staged_acknowledgement(
         {:ok, %{revision: revision}},
         revision,
         stage,
         mode
       ) do
    {:ok, %{revision: revision, outbox: Map.fetch!(stage, :outbox), mode: mode}}
  end

  defp validate_staged_acknowledgement(
         {:ok, %{revision: received}},
         expected,
         _stage,
         _mode
       )
       when is_integer(received) do
    {:error,
     Error.new(:resource_conflict, "invalid stage revision",
       details: %{expected: expected, received: received}
     )}
  end

  defp validate_staged_acknowledgement({:error, %Error{} = error}, _expected, _stage, _mode),
    do: {:error, error}

  defp validate_staged_acknowledgement(other, _expected, _stage, _mode) do
    {:error,
     Error.new(:execution_failure, "store returned an invalid acknowledgement",
       details: %{received: other}
     )}
  end

  @spec store(module(), term(), map(), map()) ::
          {:ok, %{revision: non_neg_integer(), outbox: list()}} | {:error, Error.t()}
  def store(impl, context, record, meta)
      when is_atom(impl) and is_map(record) and is_map(meta) do
    with {:ok, mode} <- validate_mode(impl),
         {:ok, _capabilities} <- validate_durable_or_ephemeral_capabilities(impl),
         {:ok, revision} <- expected_revision(record) do
      expected_committed_revision = revision + 1

      case impl.store(context, record, meta) do
        {:ok, %{revision: ^expected_committed_revision, outbox: outbox} = result}
        when is_list(outbox) ->
          {:ok, Map.put(result, :mode, mode)}

        {:ok, %{revision: ^expected_committed_revision} = result} ->
          {:error,
           Error.new(:execution_failure, "store returned an invalid acknowledgement",
             details: %{received: result}
           )}

        {:ok, %{revision: committed_revision}}
        when is_integer(committed_revision) ->
          {:error,
           Error.new(:resource_conflict, "store returned an invalid revision",
             details: %{expected: expected_committed_revision, received: committed_revision}
           )}

        {:ok, result} ->
          {:error,
           Error.new(:execution_failure, "store returned an invalid acknowledgement",
             details: %{received: result}
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

    required = [:expected_revision, :transition_events, :outbox_intents]

    if is_map(capabilities) and Enum.all?(required, &(Map.get(capabilities, &1) == true)) do
      {:ok, capabilities}
    else
      {:error,
       Error.new(
         :unsupported_capability,
         "store must declare expected_revision, transition_events, and outbox_intents"
       )}
    end
  end

  @spec validate_durable_capabilities(module()) :: {:ok, map()} | {:error, Error.t()}
  def validate_durable_capabilities(impl) when is_atom(impl) do
    with {:ok, capabilities} <- validate_capabilities(impl) do
      required = [
        :atomic_transition_outbox,
        :recovery_records,
        :artifact_references
      ]

      if Enum.all?(required, &(Map.get(capabilities, &1) == true)) do
        {:ok, capabilities}
      else
        {:error,
         Error.new(
           :unsupported_capability,
           "durable store must declare atomic_transition_outbox, recovery_records, and artifact_references"
         )}
      end
    end
  end

  defp validate_durable_or_ephemeral_capabilities(impl) do
    if impl.mode() == :durable do
      validate_durable_capabilities(impl)
    else
      validate_capabilities(impl)
    end
  end

  defp expected_revision(%{expected_revision: revision})
       when is_integer(revision) and revision >= 0,
       do: {:ok, revision}

  defp expected_revision(_record) do
    {:error, Error.new(:validation, "record expected_revision is required")}
  end
end
