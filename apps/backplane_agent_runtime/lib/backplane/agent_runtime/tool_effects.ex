defmodule Backplane.AgentRuntime.ToolEffects do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Tool effects and cancellation boundary for Backplane agent runtime.
  """

  @type adapter :: module()

  @callback execute(map()) :: {:ok, map()} | {:error, Error.t()}

  @callback cancel(map()) :: :ok | {:error, Error.t()}

  @default_output_limit 1_048_576

  @spec execute(adapter(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def execute(adapter, invocation, context)
      when is_atom(adapter) and is_map(invocation) and is_map(context) do
    with {:ok, invocation} <- validate_invocation(invocation),
         {:ok, result} <- adapter.execute(invocation) do
      {:ok, Map.put(invocation, :result, result)}
    else
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
