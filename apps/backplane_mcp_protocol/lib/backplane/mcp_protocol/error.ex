defmodule Backplane.McpProtocol.Error do
  @moduledoc """
  Structured MCP and JSON-RPC errors.
  """

  alias Backplane.McpProtocol.JsonRpc

  defstruct [:code, :reason, :message, data: %{}]

  @type t :: %__MODULE__{
          code: integer(),
          reason: atom(),
          message: String.t() | nil,
          data: term()
        }

  @protocol_errors %{
    parse_error: {-32_700, "Parse error"},
    invalid_request: {-32_600, "Invalid Request"},
    method_not_found: {-32_601, "Method not found"},
    invalid_params: {-32_602, "Invalid params"},
    internal_error: {-32_603, "Internal error"}
  }

  @code_reasons %{
    -32_700 => :parse_error,
    -32_600 => :invalid_request,
    -32_601 => :method_not_found,
    -32_602 => :invalid_params,
    -32_603 => :internal_error,
    -32_002 => :resource_not_found,
    -32_000 => :server_error
  }

  @spec protocol(atom(), term()) :: t()
  def protocol(reason, data \\ %{}) when is_atom(reason) do
    {code, message} = Map.get(@protocol_errors, reason, @protocol_errors.internal_error)
    %__MODULE__{code: code, reason: reason, message: message, data: data}
  end

  @spec transport(atom(), term()) :: t()
  def transport(reason, data \\ %{}) when is_atom(reason) do
    %__MODULE__{code: -32_000, reason: reason, message: humanize(reason), data: data}
  end

  @spec resource(atom(), term()) :: t()
  def resource(:not_found, data \\ %{}) do
    %__MODULE__{
      code: -32_002,
      reason: :resource_not_found,
      message: "Resource not found",
      data: data
    }
  end

  @spec execution(String.t(), term()) :: t()
  def execution(message, data \\ %{}) when is_binary(message) do
    %__MODULE__{code: -32_000, reason: :execution_error, message: message, data: data}
  end

  @spec from_json_rpc(map()) :: t()
  def from_json_rpc(%{"code" => code} = error) when is_integer(code) do
    %__MODULE__{
      code: code,
      reason: Map.get(@code_reasons, code, :unknown_error),
      message: Map.get(error, "message"),
      data: Map.get(error, "data", %{})
    }
  end

  @spec to_json_rpc(t(), term()) :: {:ok, String.t()} | {:error, Jason.EncodeError.t()}
  def to_json_rpc(%__MODULE__{} = error, id) do
    data = if error.data in [nil, %{}], do: nil, else: error.data

    id
    |> JsonRpc.error(error.code, error.message || "Error", data)
    |> Jason.encode()
  end

  defp humanize(reason) do
    reason
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end

defimpl Inspect, for: Backplane.McpProtocol.Error do
  import Inspect.Algebra

  def inspect(error, opts) do
    message = if error.message, do: ": #{error.message}", else: ""
    data = if error.data in [nil, %{}], do: "", else: " #{Kernel.inspect(error.data, opts)}"

    concat(["#Backplane.McpProtocol.Error<", to_string(error.reason), message, data, ">"])
  end
end
