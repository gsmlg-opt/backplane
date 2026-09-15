defmodule Backplane.Api.SkillProtocolAuthorization do
  @moduledoc "Enforces the Skill Protocol read scope after resource authentication."

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Auth.BearerChallenge
  alias Backplane.Clients

  @scope "skill::read"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{resource_auth: %{scopes: scopes, kind: kind}}} = conn, _opts) do
    if Clients.scope_matches?(scopes, @scope) do
      conn
    else
      conn
      |> maybe_challenge(kind)
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          protocol_version: "1",
          error: %{code: "forbidden", message: "insufficient scope", retryable: false}
        })
      )
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  def required_scope(_conn), do: @scope

  defp maybe_challenge(conn, :oauth),
    do: BearerChallenge.put(conn, :skill_protocol, error: "insufficient_scope", scope: @scope)

  defp maybe_challenge(conn, _kind), do: conn
end
