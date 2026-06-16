defmodule Backplane.McpProtocol.Response do
  @moduledoc """
  Wrapper for MCP JSON-RPC result responses.
  """

  defstruct [:result, :id, is_error: false]

  @type t :: %__MODULE__{
          result: term(),
          id: term(),
          is_error: boolean()
        }

  @spec from_json_rpc(map()) :: t()
  def from_json_rpc(%{"result" => result, "id" => id}) do
    %__MODULE__{result: result, id: id, is_error: domain_error?(result)}
  end

  @spec unwrap(t()) :: term()
  def unwrap(%__MODULE__{} = response), do: response.result

  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{} = response), do: not response.is_error

  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{} = response), do: response.is_error

  @spec get_result(t()) :: term()
  def get_result(%__MODULE__{} = response), do: response.result

  @spec get_id(t()) :: term()
  def get_id(%__MODULE__{} = response), do: response.id

  defp domain_error?(%{"isError" => true}), do: true
  defp domain_error?(_result), do: false
end
