defmodule Backplane.AgentRuntime.StoreConformance do
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Recovery
  alias Backplane.AgentRuntime.Store

  @moduledoc """
  Reusable executable contract for host-provided durable stores.

  `run/3` uses unique run IDs supplied by the host and exercises the public
  `Store` boundary. The host supplies three small test seams:

    * `:restart` reconnects to the same durable namespace;
    * `:fail_next_commit` makes the next staged commit fail before acceptance;
    * `:dependent_effect_count` reports effects launched for a run by the host.

  Passing this deterministic harness proves that the adapter exposes the
  package contract under the injected scenarios. It does not by itself prove a
  database or filesystem's power-loss durability; consumers must run it against
  their real adapter and document that backend's acknowledgement boundary.
  """

  @checks [
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

  @type result :: %{mode: :durable, checks: [atom()]}

  @spec run(module(), term(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(impl, context, opts) when is_atom(impl) and is_list(opts) do
    with {:ok, :durable} <- durable_mode(impl),
         {:ok, _capabilities} <- Store.validate_durable_capabilities(impl),
         {:ok, run_id} <- required_binary(opts, :run_id),
         {:ok, restart} <- required_callback(opts, :restart, 1),
         {:ok, fail_next_commit} <- required_callback(opts, :fail_next_commit, 1),
         {:ok, dependent_effect_count} <-
           required_callback(opts, :dependent_effect_count, 2),
         :ok <- direct_execution_commit(impl, context, run_id, restart),
         :ok <- committed_and_restarted(impl, context, run_id, restart),
         :ok <- failed_commit(impl, context, run_id, fail_next_commit, dependent_effect_count),
         :ok <- fenced_recovery(impl, context, run_id),
         :ok <- terminal_reconstruction(impl, context, run_id, restart) do
      {:ok, %{mode: :durable, checks: @checks}}
    end
  end

  def run(_impl, _context, _opts),
    do: {:error, Error.new(:validation, "invalid store conformance configuration")}

  defp direct_execution_commit(impl, context, prefix, restart) do
    run = base_run("#{prefix}:direct")
    outbox = [%{id: "#{prefix}:direct-admit", type: :run_admitted}]
    meta = %{command: {:admit, 5, %{state: :running}}, outbox: outbox}

    with {:ok, %{revision: 1, outbox: ^outbox, mode: :durable}} <-
           Store.store(impl, context, run, meta),
         {:ok, snapshot} <- load(impl, context, run.run_id),
         true <- snapshot.revision == 1,
         true <- snapshot.run.state == :running,
         true <- snapshot.run.expected_revision == 1,
         true <- snapshot.outbox == outbox,
         {:error, %Error{class: :resource_conflict}} <- Store.store(impl, context, run, meta),
         {:ok, restarted_context} <- invoke(restart, [context], "restart"),
         {:ok, restarted} <- load(impl, restarted_context, run.run_id),
         true <- restarted == snapshot do
      :ok
    else
      false -> error(:execution_failure, "direct execution commit did not reconstruct")
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("direct execution commit", other)
    end
  end

  defp committed_and_restarted(impl, context, prefix, restart) do
    run = base_run("#{prefix}:active")
    outbox = [%{id: "#{prefix}:admit", type: :run_admitted}]

    conversation = %{
      messages: [%{id: "message_1", role: :user, content: "persist me"}],
      steering: [],
      follow_up: [%{id: "message_2", role: :user, content: "later"}],
      usage: [%{input_tokens: 3, output_tokens: 0}],
      host_projection: %{session_revision: 7}
    }

    budget = %{quota: 2, used: 1, reservations: %{"provider:attempt_1" => 1}}

    intent = %{
      type: :provider,
      status: :started,
      reservation: %{reservation_id: "provider:attempt_1"}
    }

    with {:ok, staged, snapshot} <-
           commit(impl, context, run, %{
             command: {:admit, 10, %{state: :running}},
             incarnation: 1,
             outbox: outbox
           }),
         :ok <- validate_snapshot(snapshot, staged.stage),
         {:error, %Error{class: :resource_conflict}} <-
           Store.acknowledge_commit(impl, context, staged.stage, %{}),
         {:ok, _checkpoint, snapshot} <-
           commit(impl, context, snapshot.run, %{
             command:
               {:conversation_updated, 11,
                provider_identity(snapshot.run, "checkpoint", "checkpoint")
                |> Map.put(:conversation, conversation)},
             incarnation: 1
           }),
         {:ok, _effect, snapshot} <-
           commit(impl, context, snapshot.run, %{
             command:
               {:provider_started, 12,
                provider_identity(snapshot.run, "step_1", "attempt_1")
                |> Map.put(:execution_intent, intent)
                |> Map.put(:execution_budget, budget)},
             incarnation: 1,
             outbox: [intent]
           }),
         {:ok, restarted_context} <- invoke(restart, [context], "restart"),
         {:ok, restarted} <- load(impl, restarted_context, run.run_id),
         true <- restarted == snapshot,
         true <- get_in(restarted, [:run, :context, :conversation]) == conversation,
         true <- get_in(restarted, [:run, :active_provider, :attempt_id]) == "attempt_1",
         true <- restarted.run.execution_budget == budget do
      :ok
    else
      false ->
        error(
          :execution_failure,
          "restart changed the committed context, budget, or outstanding effect"
        )

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        invalid_result("committed/restart scenario", other)
    end
  end

  defp failed_commit(impl, context, prefix, fail_next_commit, dependent_effect_count) do
    run = base_run("#{prefix}:failed")

    with :ok <- callback_ok(fail_next_commit, [context], "fail_next_commit"),
         {:error, %Error{}} <-
           Store.store(impl, context, run, %{
             command: {:admit, 20, %{state: :running}},
             outbox: [%{id: "#{prefix}:must-not-dispatch", type: :provider}]
           }),
         {:error, %Error{class: :not_found}} <- load(impl, context, run.run_id),
         {:ok, 0} <-
           invoke(dependent_effect_count, [context, run.run_id], "dependent_effect_count") do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("failed commit scenario", other)
    end
  end

  defp fenced_recovery(impl, context, prefix) do
    run_id = "#{prefix}:active"

    with {:ok, snapshot} <- load(impl, context, run_id),
         {:ok, fenced} <-
           Store.fence(
             impl,
             context,
             run_id,
             snapshot.revision,
             snapshot.run.incarnation,
             snapshot.run.incarnation + 1
           ),
         {:error, %Error{class: :resource_conflict}} <-
           Store.fence(
             impl,
             context,
             run_id,
             snapshot.revision,
             snapshot.run.incarnation,
             snapshot.run.incarnation + 2
           ),
         {:ok, persisted} <- load(impl, context, run_id),
         :ok <- validate_fenced_snapshot(persisted, fenced),
         {:ok, recovery} <-
           Recovery.recover(
             %{
               run_id: run_id,
               incarnation: persisted.run.incarnation,
               effects: [
                 %{
                   effect_id: "#{prefix}:uncertain-mutation",
                   class: :mutation,
                   dispatch: %{state: :unknown},
                   outcome: :unknown
                 }
               ]
             },
             %{incarnation: persisted.run.incarnation + 1}
           ),
         false <- Enum.any?(recovery.uncertain_effects, & &1.safe_to_resume?) do
      :ok
    else
      true -> error(:execution_failure, "uncertain mutation was marked safe to resume")
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("incarnation recovery scenario", other)
    end
  end

  defp terminal_reconstruction(impl, context, prefix, restart) do
    run = base_run("#{prefix}:terminal")
    provider = provider_identity(run, "step_1", "attempt_1")
    budget = %{quota: 1, used: 1, reservations: %{"provider:attempt_1" => 1}}

    intent = %{
      type: :provider,
      status: :started,
      reservation: %{reservation_id: "provider:attempt_1"}
    }

    with {:ok, _staged, admitted} <-
           commit(impl, context, run, %{
             command: {:admit, 30, %{state: :running}},
             incarnation: 1
           }),
         {:ok, _staged, started} <-
           commit(impl, context, admitted.run, %{
             command:
               {:provider_started, 31,
                provider
                |> Map.put(:execution_intent, intent)
                |> Map.put(:execution_budget, budget)},
             incarnation: 1
           }),
         {:ok, _staged, terminal} <-
           commit(impl, context, started.run, %{
             command:
               {:provider_completed, 32,
                provider
                |> Map.put(:final?, true)
                |> Map.put(:outcome, %{"text" => "done"})},
             incarnation: 1
           }),
         {:ok, restarted_context} <- invoke(restart, [context], "restart"),
         {:ok, reconstructed} <- load(impl, restarted_context, run.run_id),
         :ok <- validate_terminal(reconstructed, terminal, budget) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("terminal reconstruction scenario", other)
    end
  end

  defp commit(impl, context, run, meta) do
    with {:ok, staged} <- Store.stage(impl, context, run, meta),
         {:ok, %{revision: revision}} <-
           Store.acknowledge_commit(impl, context, staged.stage, %{}),
         {:ok, snapshot} <- load(impl, context, run.run_id),
         true <- snapshot.revision == revision do
      {:ok, staged, snapshot}
    else
      false -> error(:resource_conflict, "loaded revision did not match acknowledgement")
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("commit", other)
    end
  end

  defp validate_snapshot(snapshot, stage) do
    required = [:run, :revision, :transition, :effects, :outbox, :incarnation]

    if Map.take(snapshot, required) == Map.take(stage, required) do
      :ok
    else
      error(:execution_failure, "durable snapshot omitted committed transition data")
    end
  end

  defp validate_fenced_snapshot(snapshot, fenced) do
    if snapshot.revision == fenced.revision and snapshot.run == fenced.run and
         snapshot.incarnation == fenced.run.incarnation do
      :ok
    else
      error(:resource_conflict, "incarnation fence was not reconstructed")
    end
  end

  defp validate_terminal(reconstructed, committed, budget) do
    run = reconstructed.run

    if reconstructed == committed and run.state == :completed and
         run.outcome == %{"text" => "done"} and run.execution_budget == budget and
         is_nil(run.active_provider) do
      :ok
    else
      error(:execution_failure, "terminal state, outcome, or budget did not reconstruct")
    end
  end

  defp load(impl, context, run_id) do
    case impl.load(context, run_id, []) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result("load", other)
    end
  end

  defp durable_mode(impl) do
    case Store.validate_mode(impl) do
      {:ok, :durable} -> {:ok, :durable}
      {:ok, :ephemeral} -> error(:unsupported_capability, "durable store required")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp required_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> error(:validation, "#{key} is required")
    end
  end

  defp required_callback(opts, key, arity) do
    case Keyword.get(opts, key) do
      callback when is_function(callback, arity) -> {:ok, callback}
      _ -> error(:validation, "#{key}/#{arity} callback is required")
    end
  end

  defp callback_ok(callback, args, name) do
    case apply(callback, args) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result(name, other)
    end
  end

  defp invoke(callback, args, name) do
    case apply(callback, args) do
      {:ok, value} -> {:ok, value}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
      other -> invalid_result(name, other)
    end
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

  defp provider_identity(run, step_id, attempt_id) do
    %{
      run_id: run.run_id,
      incarnation: run.incarnation,
      step_id: step_id,
      attempt_id: attempt_id
    }
  end

  defp invalid_result(operation, received) do
    error(:execution_failure, "invalid #{operation} result", %{received: received})
  end

  defp error(class, message, details \\ %{}) do
    {:error, Error.new(class, message, details: details)}
  end
end
