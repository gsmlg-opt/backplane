defmodule Backplane.Api.PluginAuthorization do
  @moduledoc "Plugin registry scopes on the existing MCP protected resource."
  @behaviour Plug
  import Plug.Conn
  alias Backplane.Auth.BearerChallenge
  alias Backplane.Clients

  def init(opts), do: opts

  def required_scope(%{method: method, path_info: path}) do
    case {method, path} do
      {"POST", ["plugin-protocol", "v1", "installations", _id, "report"]} ->
        "plugin::install"

      {"GET", ["plugin-protocol", "v1", name]}
      when name in ["catalog", "resolve", "installations"] ->
        "plugin::read"

      {"GET", ["plugin-protocol", "v1", "artifacts", _digest]} ->
        "plugin::read"

      _ ->
        "plugin::manage"
    end
  end

  def call(%{assigns: %{resource_auth: auth}} = conn, _opts) do
    scope = required_scope(conn)

    if Clients.scope_matches?(auth.scopes, scope) do
      conn
    else
      conn
      |> BearerChallenge.put(:mcp, error: "insufficient_scope", scope: scope)
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: %{code: "forbidden", message: "insufficient plugin scope"}})
      )
      |> halt()
    end
  end
end
