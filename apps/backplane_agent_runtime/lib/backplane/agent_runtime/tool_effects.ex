defmodule Backplane.AgentRuntime.ToolEffects do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Tool effects and cancellation boundary for Backplane agent runtime.
  """

  @type adapter :: module()

  defmodule Rejection do
    @moduledoc "Invocation-bound assertion from a trusted backend that no tool was dispatched."
    @enforce_keys [:identity, :error]
    defstruct [:identity, :error]

    @type t :: %__MODULE__{identity: map(), error: Backplane.AgentRuntime.Error.t()}
  end

  defmodule Cancellation do
    @moduledoc "Exact trusted local cancellation evidence; never a remote rollback receipt."
    @enforce_keys [:identity, :evidence]
    defstruct [:identity, :evidence]
    @type t :: %__MODULE__{identity: map(), evidence: map()}
  end

  defmodule AggregateCancellation do
    @moduledoc "Exact sealed sequential resource inventory, independent of single-request cancellation."
    @enforce_keys [:identity, :evidence]
    defstruct [:identity, :evidence]
    @type t :: %__MODULE__{identity: map(), evidence: map()}
  end

  defmodule Retirement do
    @moduledoc "Typed native observation retirement; business outcome remains unknown."
    @enforce_keys [:identity, :evidence]
    defstruct [:identity, :evidence]
    @type t :: %__MODULE__{identity: map(), evidence: map()}
  end

  defmodule Presentation do
    @moduledoc "A trusted backend's invocation-bound result and consumer presentation."
    @enforce_keys [:identity, :result, :decision]
    defstruct [:identity, :result, :decision]
    @type t :: %__MODULE__{identity: map(), result: map(), decision: map()}
  end

  defmodule PresentedResult do
    @moduledoc false
    @enforce_keys [:result, :presentation]
    defstruct [:result, :presentation]
    @type t :: %__MODULE__{result: map(), presentation: map()}
  end

  @type result ::
          {:ok, map()}
          | {:error, Error.t()}
          | {:rejected, Rejection.t()}
          | {:presented, Presentation.t()}

  @callback execute(map()) :: result()

  @callback cancel(map()) ::
              :ok
              | {:ok, Cancellation.t() | AggregateCancellation.t() | Retirement.t()}
              | {:error, Error.t()}

  @default_output_limit 1_048_576

  @identity_fields ~w(run_id incarnation step_id attempt_id invocation_id tool_name tool_revision catalog_revision tool_call_id turn_id arguments collaboration_binding)a

  @doc false
  def cancellation_identity(operation),
    do:
      Map.take(operation, [:enclosing_invocation_id, :session_binding_identity | @identity_fields])

  @doc false
  def confirm_cancellation(operation, evidence) do
    assertion = %Cancellation{identity: cancellation_identity(operation), evidence: evidence}

    with {:ok, _} <- validate_cancellation(assertion, operation), do: {:ok, assertion}
  end

  @doc false
  def validate_cancellation(%Cancellation{identity: identity, evidence: evidence}, operation) do
    with true <- valid_identity?(identity),
         true <- identity === cancellation_identity(operation),
         true <- is_map(evidence) and evidence[:local_cleanup] === :confirmed,
         true <- evidence[:stop_generation] === operation[:stop_generation],
         true <- is_binary(evidence[:stop_generation]) and evidence[:stop_generation] != "",
         true <- evidence[:registration_id] === operation[:resource_registration],
         true <- evidence[:local] === :cancelled and evidence[:remote] === :unknown,
         true <-
           Enum.all?([:logical_id, :request_id, :client_incarnation, :method], fn key ->
             is_binary(evidence[key]) and evidence[key] != ""
           end),
         %{workers_down: true, transport: :confirmed, worker_count: count} <-
           evidence[:cleanup_evidence],
         true <- is_integer(count) and count >= 0,
         registration when is_binary(registration) and registration != "" <-
           evidence[:registration_id],
         {:ok, public} <- Backplane.AgentRuntime.Codex.Reconciliation.Evidence.public(evidence) do
      {:ok, public}
    else
      _ -> unverified_cancellation()
    end
  end

  def validate_cancellation(
        %AggregateCancellation{identity: identity, evidence: evidence},
        operation
      ) do
    alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

    with true <- valid_identity?(identity),
         true <- identity === cancellation_identity(operation),
         true <- is_map(evidence),
         true <-
           exact_fields?(
             evidence,
             ~w(schema_version record_type registration_id scope_generation stop_generation gate inventory_count inventory_digest slots local_cleanup remote)a
           ),
         true <-
           evidence[:schema_version] === 1 &&
             evidence[:record_type] === :resource_scope_cancellation,
         true <- evidence[:registration_id] === operation[:resource_registration],
         %{registration: registration, generation: scope_generation} <-
           operation[:resource_scope_admission],
         true <-
           registration === evidence[:registration_id] &&
             scope_generation === evidence[:scope_generation],
         true <- evidence[:stop_generation] === operation[:stop_generation],
         true <-
           Enum.all?(
             [:registration_id, :scope_generation, :stop_generation],
             &(is_binary(evidence[&1]) && evidence[&1] != "")
           ),
         true <-
           evidence[:gate] === :sealed && evidence[:local_cleanup] === :confirmed &&
             evidence[:remote] === :unknown,
         slots when is_list(slots) <- evidence[:slots],
         count when is_integer(count) and count >= 0 and count <= 128 <-
           evidence[:inventory_count],
         true <- length(slots) === count,
         {:ok, ^count} <-
           Backplane.AgentRuntime.Codex.ResourceScope.sealed_inventory_count(operation),
         true <- valid_aggregate_slots?(slots),
         {:ok, original_digest} <-
           Backplane.AgentRuntime.Codex.ResourceScope.sealed_inventory_digest(operation),
         true <- original_digest === evidence[:inventory_digest],
         {:ok, public} <- Evidence.public(evidence),
         true <- evidence[:inventory_digest] === Evidence.digest(slots) do
      {:ok, public}
    else
      _ -> unverified_cancellation()
    end
  end

  def validate_cancellation(%Retirement{identity: identity, evidence: evidence}, operation) do
    with true <- identity === cancellation_identity(operation),
         {:ok, proof} <- validate_retirement_record(evidence, operation),
         true <- proof["record_type"] == "native_plugin_wait_retirement",
         true <- proof["plugin_request_id"] === operation[:plugin_request_id],
         true <- proof["registration_id"] === operation[:resource_registration],
         true <- proof["stop_generation"] === operation[:stop_generation] do
      {:ok, proof}
    else
      _ -> unverified_cancellation()
    end
  end

  def validate_cancellation(_, _), do: unverified_cancellation()

  @doc false
  def confirm_aggregate_cancellation(operation, evidence) do
    assertion = %AggregateCancellation{
      identity: cancellation_identity(operation),
      evidence: evidence
    }

    with {:ok, _} <- validate_cancellation(assertion, operation), do: {:ok, assertion}
  end

  defp valid_aggregate_slots?(slots) do
    valid =
      Enum.with_index(slots, 1)
      |> Enum.all?(fn {slot, index} ->
        exact_fields?(slot, ~w(index identity receipt phase)a) && slot[:index] === index &&
          slot[:phase] === :retired &&
          Backplane.AgentRuntime.Codex.ResourceScope.valid_receipt?(
            slot[:receipt],
            slot[:identity]
          )
      end)

    valid && Enum.uniq_by(slots, & &1[:identity]) === slots
  end

  @doc false
  def confirm_retirement(operation, proof) do
    assertion = %Retirement{identity: cancellation_identity(operation), evidence: proof}
    with {:ok, _} <- validate_cancellation(assertion, operation), do: {:ok, assertion}
  end

  @doc false
  def validate_retirement_record(proof, operation) when is_map(proof) and is_map(operation) do
    alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

    with true <- valid_identity?(cancellation_identity(operation)),
         {:ok, ^proof} <- Evidence.public(proof),
         {:ok, identity} <- Evidence.public(cancellation_identity(operation)),
         true <- proof["identity"] === identity,
         true <- proof["schema_version"] === 1,
         true <- proof["local_cleanup"] === "confirmed" and proof["outcome"] === "unknown",
         true <-
           proof["retirement_digest"] === Evidence.digest(Map.delete(proof, "retirement_digest")),
         true <- retirement_fields?(proof, identity) do
      {:ok, proof}
    else
      _ -> unverified_cancellation()
    end
  end

  def validate_retirement_record(_, _), do: unverified_cancellation()

  defp retirement_fields?(%{"record_type" => "native_plugin_wait_retirement"} = proof, identity) do
    exact_fields?(
      proof,
      ~w(schema_version record_type identity plugin_request_id host_request_ref registration_id stop_generation provenance completion_gate waiter_down local_cleanup outcome retirement_digest)
    ) and
      exact_fields?(proof["provenance"], ~w(runtime_id session_binding_identity)) and
      identity["tool_name"] == "request_plugin_install" and proof["waiter_down"] === true and
      proof["completion_gate"] === "closed" and
      Enum.all?(
        ~w(plugin_request_id host_request_ref registration_id stop_generation),
        &(is_binary(proof[&1]) and proof[&1] != "")
      ) and
      is_map(proof["provenance"]) and is_binary(proof["provenance"]["runtime_id"]) and
      proof["provenance"]["session_binding_identity"] === identity["session_binding_identity"]
  end

  defp retirement_fields?(%{"record_type" => "code_mode_retirement"} = proof, identity) do
    exact_fields?(
      proof,
      ~w(schema_version record_type identity stop_generation provenance executor_down resources nested local_cleanup outcome retirement_digest)
    ) and
      exact_fields?(proof["provenance"], ~w(session_binding_identity)) and
      proof["provenance"]["session_binding_identity"] === identity["session_binding_identity"] and
      identity["tool_name"] in ["exec", "wait"] and proof["executor_down"] === true and
      proof["resources"] === "confirmed" and is_list(proof["nested"]) and proof["nested"] != [] and
      is_binary(proof["stop_generation"]) and proof["stop_generation"] != "" and
      Enum.all?(proof["nested"], fn nested ->
        exact_fields?(nested, ~w(kind identity evidence_digest)) and is_map(nested["identity"]) and
          nested["identity"]["enclosing_invocation_id"] === identity["invocation_id"] and
          is_binary(nested["evidence_digest"]) and
          nested["kind"] in ["acknowledged_settlement", "native_plugin_wait_retirement"]
      end) and
      length(Enum.uniq_by(proof["nested"], & &1["identity"]["invocation_id"])) ==
        length(proof["nested"])
  end

  defp retirement_fields?(_, _), do: false

  defp exact_fields?(value, fields) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp exact_fields?(_, _), do: false

  defp unverified_cancellation,
    do:
      {:error,
       Error.new(:unknown_outcome, "tool cancellation lacks exact local cleanup evidence")}

  @doc """
  Rejects an invocation before dispatching any tool or external effect.

  Only the registered, trusted backend may make this assertion, after its host
  approval/catalog checks and before dispatch. It is not a reconciliation receipt
  for work that was started. Generic errors and error details do not prove
  non-execution. An unknown outcome cannot be turned into a rejection.

  The rejection binds the runtime operation identity and exact arguments; the
  execution boundary validates it before publishing a structured tool error.
  """
  @spec reject(map(), Error.t()) :: {:rejected, Rejection.t()} | {:error, Error.t()}
  def reject(operation, %Error{} = error) when is_map(operation) do
    identity = Map.take(operation, @identity_fields)

    if valid_identity?(identity) and error.class != :unknown_outcome do
      {:rejected, %Rejection{identity: identity, error: error}}
    else
      unverified_rejection()
    end
  end

  @doc """
  Preserves an actual native result while selecting durable consumer presentation.

  A trusted backend calls this after native completion. `%{type: :block, text: ...}`
  returns a consumer error (including to Code Mode); `:stopped` replaces model
  output while nested Code Mode retains the original value. Additional context is
  independently delivered through `append_feedback`. This is never non-dispatch
  evidence. The Runtime validates exact identity and persists both values before
  replying. Unacknowledged Store settlement remains uncertain and is not replayed.
  """
  def present(operation, result, decision) when is_map(operation) and is_map(result) do
    presentation = %Presentation{
      identity: presentation_identity(operation),
      result: result,
      decision: decision
    }

    case validate_presentation(presentation, operation) do
      {:ok, _} -> {:presented, presentation}
      error -> error
    end
  end

  def present(_, _, _), do: invalid_presentation()

  @doc false
  def validate_presentation(
        %Presentation{identity: identity, result: result, decision: decision},
        operation
      ) do
    if valid_identity?(identity) and identity == presentation_identity(operation) and
         is_binary(identity[:tool_call_id]) and is_binary(identity[:turn_id]) and
         is_binary(identity[:enclosing_invocation_id]) and is_integer(identity[:catalog_revision]) and
         is_map(result) and valid_decision?(decision) do
      {:ok,
       %PresentedResult{
         result: result,
         presentation: %{identity: identity, decision: decision, state: :accepted}
       }}
    else
      invalid_presentation()
    end
  end

  def validate_presentation(_, _), do: invalid_presentation()

  @doc false
  def validate_presentation_record(
        %{identity: identity, decision: decision, state: :accepted} = record,
        operation,
        result
      )
      when map_size(record) == 3 and is_map(operation) and is_map(result) do
    case validate_presentation(
           %Presentation{identity: identity, decision: decision, result: result},
           operation
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def validate_presentation_record(_, _, _), do: invalid_presentation()

  defp valid_decision?(%{type: type, text: text} = decision),
    do:
      type in [:block, :stopped] and is_binary(text) and String.valid?(text) and
        byte_size(text) <= 65_536 and (type == :stopped or text != "") and
        map_size(decision) == 2

  defp valid_decision?(_), do: false

  @doc false
  def presentation_identity(operation),
    do:
      Map.take(operation, [:enclosing_invocation_id, :session_binding_identity | @identity_fields])

  defp invalid_presentation,
    do:
      {:error,
       Error.new(:unknown_outcome, "result presentation does not match the completed invocation")}

  @doc false
  @spec validate_rejection(Rejection.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def validate_rejection(%Rejection{identity: identity, error: %Error{} = error}, operation)
      when is_map(operation) do
    if valid_identity?(identity) and identity == Map.take(operation, @identity_fields) and
         error.class != :unknown_outcome do
      {:ok, %{is_error: true, error: error}}
    else
      unverified_rejection()
    end
  end

  def validate_rejection(_rejection, _operation), do: unverified_rejection()

  defp valid_identity?(identity) when is_map(identity) do
    Enum.all?(~w(run_id step_id attempt_id invocation_id tool_name)a, fn field ->
      value = Map.get(identity, field)
      is_binary(value) and value != ""
    end) and
      Enum.all?([:incarnation, :tool_revision], fn field ->
        value = Map.get(identity, field)
        is_integer(value) and value > 0
      end) and
      (is_map(identity[:arguments]) or is_binary(identity[:arguments]))
  end

  defp valid_identity?(_identity), do: false

  defp unverified_rejection,
    do: {:error, Error.new(:unknown_outcome, "tool rejection does not prove exact non-dispatch")}

  @doc "Classifies an observed backend result using its admitted descriptor safety."
  @spec settlement(term(), map()) :: :settled | :uncertain
  def settlement({:ok, result}, _safety) when is_map(result), do: :settled
  def settlement({:error, %Error{class: :unknown_outcome}}, _safety), do: :uncertain
  def settlement({:error, %Error{}}, %{read_only: true}), do: :settled
  def settlement(_outcome, _safety), do: :uncertain

  @spec execute(adapter(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def execute(adapter, invocation, context)
      when is_atom(adapter) and is_map(invocation) and is_map(context) do
    with {:ok, invocation} <- validate_invocation(invocation),
         {:ok, result} when not is_struct(result, PresentedResult) <- adapter.execute(invocation) do
      {:ok, Map.put(invocation, :result, result)}
    else
      {:ok, %PresentedResult{}} ->
        invalid_presentation()

      {:presented, presentation} ->
        with {:ok, result} <- validate_presentation(presentation, invocation),
             do: {:ok, Map.put(invocation, :result, result)}

      {:rejected, rejection} ->
        with {:ok, result} <- validate_rejection(rejection, invocation),
             do: {:ok, Map.put(invocation, :result, result)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_invocation(invocation) do
    if Map.has_key?(invocation, :invocation_id) do
      {:ok, invocation}
    else
      {:error, Error.new(:validation, "tool invocation requires invocation_id")}
    end
  end

  @spec cancel(adapter(), map()) ::
          :ok
          | {:ok, Cancellation.t() | AggregateCancellation.t() | Retirement.t()}
          | {:error, Error.t()}
  def cancel(adapter, invocation) when is_atom(adapter) and is_map(invocation) do
    with {:ok, _} <- validate_invocation(invocation) do
      adapter.cancel(invocation)
    end
  end

  @spec validate_output(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def validate_output(output, opts \\ []) when is_map(output) do
    limit = Keyword.get(opts, :limit, @default_output_limit)
    payload = Map.get(output, :payload)
    size = :erlang.external_size(payload)

    with :ok <- Backplane.AgentRuntime.ProviderOutput.validate_limit(limit, :output_limit, false) do
      if size > limit do
        {:error,
         Error.new(:resource_conflict, "tool output exceeds the configured bound",
           details: %{limit: limit, size: size}
         )}
      else
        {:ok, output}
      end
    end
  end
end
