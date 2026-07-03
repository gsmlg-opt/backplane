defmodule Backplane.MCP.SSE do
  @moduledoc """
  Backplane-local SSE encoding helper backed by Backplane.McpProtocol.
  """

  @spec encode(String.t(), term()) :: String.t()
  def encode(event, data) when is_binary(event) do
    encoded_data = if is_binary(data), do: data, else: Jason.encode!(data)

    %Backplane.McpProtocol.SSE.Event{event: event, data: encoded_data}
    |> Backplane.McpProtocol.SSE.Event.encode()
  end
end
