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

  @type result :: {:ok, map()} | {:error, Error.t()} | {:rejected, Rejection.t()}

  @callback execute(map()) :: result()

  @callback cancel(map()) :: :ok | {:error, Error.t()}

  @default_output_limit 1_048_576

  @identity_fields ~w(run_id incarnation step_id attempt_id invocation_id tool_name tool_revision catalog_revision tool_call_id turn_id arguments)a

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
         {:ok, result} <- adapter.execute(invocation) do
      {:ok, Map.put(invocation, :result, result)}
    else
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

  @spec cancel(adapter(), map()) :: :ok | {:error, Error.t()}
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

    if is_integer(size) and size > limit do
      {:error,
       Error.new(:resource_conflict, "tool output exceeds the configured bound",
         details: %{limit: limit, size: size}
       )}
    else
      {:ok, output}
    end
  end
end
