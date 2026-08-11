defmodule Backplane.McpProtocol.Client.ResultRouter do
  @moduledoc false

  alias Backplane.McpProtocol.Client.MRTR
  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Response

  @modern_version "2026-07-28"

  @type route_result ::
          {:complete, Response.t(), State.t()}
          | {:input_required, MRTR.t(), State.t()}
          | {:error, Error.t(), State.t()}

  @spec route(Request.t(), term(), State.t()) :: route_result()
  def route(%Request{} = request, result, %State{} = state) do
    if modern?(state) do
      route_modern(request, result, state)
    else
      {:complete, Response.from_json_rpc(%{"id" => request.id, "result" => result}), state}
    end
  end

  defp route_modern(request, %{"resultType" => "input_required"} = result, state) do
    case MRTR.prepare(request, result) do
      {:ok, continuation} -> {:input_required, continuation, state}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp route_modern(request, %{"resultType" => result_type} = result, state) when is_binary(result_type) do
    {:complete, Response.from_json_rpc(%{"id" => request.id, "result" => result}), state}
  end

  defp route_modern(_request, _result, state) do
    {:error,
     Error.transport(:malformed_response, %{
       message: "Malformed MCP result"
     }), state}
  end

  defp modern?(%State{era: :modern}), do: true
  defp modern?(%State{negotiated_version: @modern_version}), do: true
  defp modern?(_state), do: false
end
