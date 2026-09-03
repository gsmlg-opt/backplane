defmodule Backplane.MCP.ObservabilityContext do
  @moduledoc false

  alias Backplane.MCP.AccessEvent
  alias Backplane.Observability.Context
  alias Backplane.Observability.Id

  @type t :: %{
          required(:context) => Context.t(),
          optional(:mcp_request_id) => String.t() | nil
        }

  @doc "Builds observability context from a Plug connection."
  @spec from_conn(Plug.Conn.t()) :: t()
  def from_conn(%Plug.Conn{} = conn) do
    %{
      context: Context.get(conn) || fallback_context(conn),
      mcp_request_id: mcp_request_id(conn)
    }
  end

  @doc "Reads observability context from dispatch assigns when present."
  @spec from_assigns(map()) :: t() | nil
  def from_assigns(assigns) when is_map(assigns) do
    case Map.get(assigns, :observability) || Map.get(assigns, "observability") do
      %{context: %Context{} = context} = obs ->
        %{context: context, mcp_request_id: Map.get(obs, :mcp_request_id)}

      _ ->
        nil
    end
  end

  def from_assigns(_), do: nil

  defp mcp_request_id(conn) do
    case conn.assigns[:mcp_access_event] do
      %AccessEvent{event_id: event_id} when is_binary(event_id) -> event_id
      _ -> nil
    end
  end

  defp fallback_context(conn) do
    request_id =
      conn.assigns[:request_id] ||
        conn |> Plug.Conn.get_req_header("x-request-id") |> List.first() ||
        Id.request_id()

    Context.root(request_id: request_id)
  end
end
