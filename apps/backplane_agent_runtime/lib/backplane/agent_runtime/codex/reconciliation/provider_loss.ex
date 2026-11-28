defmodule Backplane.AgentRuntime.Codex.Reconciliation.ProviderLoss do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Codex.Reconciliation
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  @identity_fields ~w(subject source root_agent_id)
  @proof_refs ~w(root_admission_ref runtime_fence_ref effect_isolation_ref)
  @fields @identity_fields ++ @proof_refs ++ ~w(schema_version source_revision provider)
  @operation_fields ~w(run_id incarnation step_id attempt_id)a
  @notice "An earlier Provider request has an unknown outcome. Do not assume it completed " <>
            "and do not replay the request or its actions. Continue from committed history " <>
            "and the new instruction."

  def load(config, request) do
    source = request["source"]

    with {:ok, evidence} <-
           Reconciliation.load_provider_loss_isolation(config, request["evidence_ref"]),
         :ok <- validate_evidence(evidence, request),
         {:ok, record} <- Reconciliation.provider_loss_record(config, source),
         :ok <- validate_source(record, source, evidence),
         {:ok, ^record} <- Reconciliation.provider_loss_record(config, source) do
      {:ok, decision_fields(request, record, evidence)}
    else
      {:ok, _} -> conflict("authoritative Store changed before isolation was accepted")
      {:error, _} = error -> error
    end
  end

  defp validate_evidence(evidence, request) do
    with :ok <- Evidence.fields(evidence, @fields, @fields),
         :ok <- Evidence.version(evidence),
         :ok <- Evidence.positive(evidence["source_revision"]),
         refs = Enum.map(@proof_refs, &evidence[&1]),
         :ok <- Evidence.each(refs, &Evidence.identifier/1),
         :ok <- Evidence.unique(refs, & &1),
         true <- Map.take(evidence, @identity_fields) === Map.take(request, @identity_fields) do
      :ok
    else
      false -> conflict("Provider loss isolation refers to a different original root")
      {:error, _} = error -> error
    end
  end

  defp validate_source(%{run: run, revision: revision} = record, source, evidence) do
    provider = run[:active_provider]

    with true <- revision === evidence["source_revision"],
         true <- run.incarnation === source["original_incarnation"],
         :ok <- validate_provider(run, provider),
         {:ok, public} <- Evidence.public(provider),
         true <- public === evidence["provider"],
         :ok <- validate_outstanding_work(record, provider) do
      :ok
    else
      false ->
        conflict(
          "Provider loss isolation differs from the authoritative Store revision or attempt"
        )

      {:error, _} = error ->
        error
    end
  end

  defp validate_provider(
         run,
         %{run_id: id, incarnation: incarnation, attempt_id: attempt} = provider
       )
       when id == run.run_id and incarnation == run.incarnation do
    recorded = get_in(run, [:provider_attempts, attempt])

    if is_binary(attempt) and attempt != "" and is_binary(provider[:step_id]) and
         provider[:step_id] != "" and is_map(recorded) and
         Map.take(recorded, @operation_fields) === provider do
      :ok
    else
      uncertain("active Provider identity is missing from the original attempt inventory")
    end
  end

  defp validate_provider(_, _), do: uncertain("original root has no identifiable active Provider")

  defp validate_outstanding_work(
         %{run: %{active_tools: tools, tool_results: results} = run, effects: [], outbox: outbox},
         provider
       )
       when tools == %{} and is_map(results) and is_list(outbox) do
    work = Kernel.cleanup_requirements(run)
    intents = Map.get(run, :execution_intents, %{})

    if work.children == [] and work.dependencies == [] and
         is_nil(run[:active_wait]) and is_nil(run[:outcome]) and
         is_map(intents) and Enum.all?(intents, &compatible_intent?(&1, run, provider)) and
         Enum.all?(outbox, &active_provider_intent?(&1, provider)) do
      :ok
    else
      uncertain("original root has other unsettled Runtime work")
    end
  end

  defp validate_outstanding_work(_, _),
    do: uncertain("original Runtime work inventory is unavailable")

  defp compatible_intent?(
         {"provider:" <> attempt, %{type: :provider, status: status, operation: operation}},
         run,
         _
       )
       when status in [:consumed, :cancelled] and is_map(operation) do
    recorded = run.provider_attempts[attempt]

    is_map(recorded) and
      Map.take(operation, @operation_fields) === Map.take(recorded, @operation_fields) and
      operation[:run_id] == run.run_id and operation[:incarnation] == run.incarnation
  end

  defp compatible_intent?(
         {"tool:" <> id, %{type: :tool, status: status, operation: operation}},
         run,
         _
       )
       when status in [:consumed, :cancelled] and is_map(operation) do
    operation[:invocation_id] == id and operation[:run_id] == run.run_id and
      operation[:incarnation] == run.incarnation and
      (status == :cancelled or Map.has_key?(run.tool_results, id))
  end

  defp compatible_intent?({"provider:" <> attempt, intent}, _, %{attempt_id: attempt} = provider),
    do: active_provider_intent?(intent, provider)

  defp compatible_intent?(_, _, _), do: false

  defp active_provider_intent?(
         %{type: :provider, status: :started, operation: operation},
         provider
       )
       when is_map(operation),
       do: Map.take(operation, @operation_fields) === provider

  defp active_provider_intent?(_, _), do: false

  defp decision_fields(request, record, evidence) do
    %{
      "mode" => request["mode"],
      "root_agent_id" => request["root_agent_id"],
      "evidence_ref" => request["evidence_ref"],
      "evidence_digest" => Evidence.digest(evidence),
      "source_revision" => record.revision,
      "historical_outcome" => %{
        "run_id" => record.run.run_id,
        "state" => "running",
        "outcome_digest" => Evidence.outcome_digest(nil),
        "certainty" => "unknown"
      },
      "unresolved_provider" => %{"identity" => evidence["provider"], "outcome" => "unknown"},
      "historical_limits" => %{
        "provider_stop" => "unconfirmed",
        "executor_stop" => "unconfirmed",
        "native_retirement" => "unconfirmed",
        "async_hooks" => "unconfirmed",
        "session_end" => "unconfirmed"
      },
      "model_notice" => @notice
    }
  end

  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
  defp uncertain(message), do: {:error, Error.new(:unknown_outcome, message)}
end
