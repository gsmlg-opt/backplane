defmodule Backplane.LLM.ResourceAuthorization do
  @moduledoc """
  Enforces operation scopes for OAuth-authenticated LLM resource requests.
  """

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Auth.BearerChallenge
  alias Backplane.Clients

  @impl true
  def init(opts), do: opts

  def required_scope(%Plug.Conn{method: "GET", request_path: "/v1"}), do: nil

  def required_scope(%Plug.Conn{method: "GET", request_path: "/v1/models"}),
    do: "llm::models"

  def required_scope(%Plug.Conn{method: "POST", path_info: ["v1" | _rest]}),
    do: "llm::invoke"

  def required_scope(_conn), do: nil

  @impl true
  def call(%Plug.Conn{assigns: %{resource_auth: %{kind: :oauth, scopes: scopes}}} = conn, _opts) do
    case required_scope(conn) do
      nil ->
        conn

      scope ->
        authorize_scope(conn, scopes, scope)
    end
  end

  def call(conn, _opts), do: conn

  defp authorize_scope(conn, scopes, scope) do
    if Clients.scope_matches?(scopes, scope) do
      conn
    else
      conn
      |> BearerChallenge.put(:v1, error: "insufficient_scope", scope: scope)
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "insufficient_scope"}))
      |> halt()
    end
  end
end
