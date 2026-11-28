defmodule Backplane.Services.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Backplane.MCP.Dispatch
  alias Backplane.Services.Diagnostics

  test "requires the exact read scope of a main MCP client for discovery and calls" do
    [search | _] = Diagnostics.tools()
    request = %{"name" => search.name, "arguments" => %{}}

    for auth <- [
          %{kind: :open, resource: :mcp, scopes: ["*"]},
          %{kind: :client_token, resource: :mcp, scopes: ["*"]},
          %{kind: :client_token, resource: :mcp, scopes: ["diagnostics::*"]},
          %{
            kind: :client_token,
            resource: {:endpoint, "secondary", :mcp},
            scopes: ["diagnostics::read"]
          },
          %{kind: :host, resource: :mcp, scopes: ["diagnostics::read"]},
          %{kind: :oauth, resource: :mcp, scopes: ["diagnostics::manage"]}
        ] do
      refute Diagnostics.allowed?(auth)
      assert {:error, :insufficient_scope} = search.handler.(%{}, auth)

      assert {:error, :insufficient_scope, _} =
               Dispatch.validate_tool_call(request, context(auth))

      refute Enum.any?(Dispatch.visible_tools(context(auth)), &Diagnostics.tool?(&1.name))
    end

    for kind <- [:oauth, :client_token] do
      auth = %{kind: kind, resource: :mcp, scopes: ["diagnostics::read"]}
      assert Diagnostics.allowed?(auth)
      assert :ok = Dispatch.validate_tool_call(request, context(auth))
    end
  end

  defp context(auth) do
    %{protocol_version: "2026-07-28", auth: auth, scopes: auth.scopes, client: nil}
  end
end
