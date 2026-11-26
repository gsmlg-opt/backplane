defmodule Backplane.Api.SkillProtocolAuthorization do
  @moduledoc "Enforces Skill Protocol operation scopes after resource authentication."

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Auth.BearerChallenge
  alias Backplane.Clients

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{resource_auth: %{scopes: scopes, kind: kind}}} = conn, _opts) do
    scope = required_scope(conn)

    cond do
      kind == :open and scope == "skill::write" ->
        conn
        |> BearerChallenge.put(:skill_protocol, scope: scope)
        |> deny(401, "unauthorized", "creating a skill requires a bearer credential")

      Clients.scope_matches?(scopes, scope) ->
        conn

      true ->
        conn
        |> maybe_challenge(kind, scope)
        |> deny(403, "forbidden", "insufficient scope")
    end
  end

  defp deny(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Formata.JSON.encode!(%{
        protocol_version: "1",
        error: %{code: code, message: message, retryable: false}
      })
    )
    |> halt()
  end

  def required_scope(%{method: "POST"}), do: "skill::write"
  def required_scope(_conn), do: "skill::read"

  defp maybe_challenge(conn, :oauth, scope),
    do: BearerChallenge.put(conn, :skill_protocol, error: "insufficient_scope", scope: scope)

  defp maybe_challenge(conn, _kind, _scope), do: conn
end
