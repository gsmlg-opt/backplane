defmodule Backplane.AgentRuntime.ToolResultContract do
  @moduledoc """
  Host-selected, invocation-bound tool result allowances.

  The optional `:tool_result_contract` execution/Conversation option is a function
  of the trusted registered descriptor and invocation identity (without tool
  arguments). It returns `:default`, `{:ok, %{output_limit: bytes, json_limit: bytes}}`,
  or `{:error, %Backplane.AgentRuntime.Error{}}`. Both limits must be positive,
  finite integers. The selected contract is persisted in the execution intent
  before dispatch and is never selected again when delivering that result.

  `output_limit` bounds the Erlang external size of the native result, as the
  existing output limit does. `json_limit` independently bounds the JSON-encoded
  nested result value. Code Mode permits at most its ordinary 1 MiB of protocol
  envelope overhead in addition to that value. Neither option changes provider
  output accounting or Code Mode program/output limits.
  """

  alias Backplane.AgentRuntime.Error

  @identity_fields ~w(run_id incarnation step_id attempt_id invocation_id tool_name tool_revision catalog_revision tool_call_id enclosing_invocation_id turn_id)a
  @maximum_limit 2_147_483_647

  defmodule Delivery do
    @moduledoc false
    @enforce_keys [:value, :contract]
    defstruct [:value, :contract]
  end

  @doc false
  def select(descriptor, invocation, opts) do
    case Keyword.get(opts, :tool_result_contract) do
      nil ->
        {:ok, nil}

      selector when is_function(selector, 2) ->
        selector.(descriptor, Map.take(invocation, @identity_fields)) |> selection()

      _ ->
        invalid("tool result contract selector must be a function of two arguments")
    end
  rescue
    _ -> invalid("tool result contract selector failed")
  catch
    _, _ -> invalid("tool result contract selector failed")
  end

  @doc false
  def validate(%{schema_version: 1, output_limit: native, json_limit: json} = contract)
      when map_size(contract) == 3 and is_integer(native) and native > 0 and
             native <= @maximum_limit and is_integer(json) and json > 0 and
             json <= @maximum_limit,
      do: :ok

  def validate(_),
    do: invalid("tool result contract requires finite positive output_limit and json_limit")

  @doc false
  def deliver({:ok, value}, contract) when is_map(contract),
    do: {:ok, %Delivery{value: value, contract: contract}}

  def deliver(result, _contract), do: result

  defp selection(:default), do: {:ok, nil}
  defp selection({:error, %Error{} = error}), do: {:error, error}

  defp selection({:ok, %{output_limit: _, json_limit: _} = limits}) when map_size(limits) == 2 do
    contract = Map.put(limits, :schema_version, 1)
    with :ok <- validate(contract), do: {:ok, contract}
  end

  defp selection(_), do: invalid("invalid tool result contract selector result")

  defp invalid(message), do: {:error, Error.new(:validation, message)}
end
