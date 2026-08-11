defmodule Backplane.McpProtocol.Client.MRTR do
  @moduledoc false

  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.MCP.Error

  @supported_methods ~w(tools/call prompts/get resources/read)

  @enforce_keys [
    :method,
    :base_params,
    :input_requests,
    :input_requests_present?,
    :request_state,
    :request_state_present?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          method: String.t(),
          base_params: map(),
          input_requests: map(),
          input_requests_present?: boolean(),
          request_state: String.t() | nil,
          request_state_present?: boolean()
        }

  @spec prepare(Request.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def prepare(%Request{method: method} = request, %{"resultType" => "input_required"} = result)
      when method in @supported_methods do
    input_requests_present? = Map.has_key?(result, "inputRequests")
    request_state_present? = Map.has_key?(result, "requestState")
    input_requests = Map.get(result, "inputRequests", %{})
    request_state = Map.get(result, "requestState")

    if (input_requests_present? or request_state_present?) and is_map(input_requests) and
         (not request_state_present? or is_binary(request_state)) do
      {:ok,
       %__MODULE__{
         method: method,
         base_params: request.base_params || request.params || %{},
         input_requests: input_requests,
         input_requests_present?: input_requests_present?,
         request_state: request_state,
         request_state_present?: request_state_present?
       }}
    else
      malformed()
    end
  end

  def prepare(%Request{}, %{"resultType" => "input_required"}), do: malformed()
  def prepare(%Request{}, _result), do: malformed()

  @spec retry_params(t(), map()) :: map()
  def retry_params(%__MODULE__{} = continuation, input_responses) when is_map(input_responses) do
    continuation.base_params
    |> Map.delete("inputResponses")
    |> Map.delete("requestState")
    |> maybe_put("inputResponses", input_responses, continuation.input_requests_present?)
    |> maybe_put("requestState", continuation.request_state, continuation.request_state_present?)
  end

  defp maybe_put(params, _key, _value, false), do: params
  defp maybe_put(params, key, value, true), do: Map.put(params, key, value)

  defp malformed do
    {:error,
     Error.transport(:malformed_response, %{
       message: "Malformed MCP result"
     })}
  end
end
