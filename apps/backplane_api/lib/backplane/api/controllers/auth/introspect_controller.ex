defmodule Backplane.Api.Auth.IntrospectController do
  use Backplane.Api, :controller

  @behaviour Boruta.Oauth.IntrospectApplication

  alias Backplane.Api.Auth.Helpers
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.IntrospectResponse

  def introspect(conn, params) do
    case Helpers.check_client_enabled(conn, params) do
      :ok -> Boruta.Oauth.introspect(conn, __MODULE__)
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
    end
  end

  @impl Boruta.Oauth.IntrospectApplication
  def introspect_success(conn, %IntrospectResponse{active: true} = response) do
    json(conn, %{
      active: true,
      client_id: response.client_id,
      username: response.username,
      scope: response.scope,
      sub: response.sub,
      iss: response.iss,
      exp: response.exp,
      iat: response.iat
    })
  end

  def introspect_success(conn, %IntrospectResponse{}) do
    json(conn, %{active: false})
  end

  @impl Boruta.Oauth.IntrospectApplication
  def introspect_error(conn, %Error{error: :invalid_client}) do
    Helpers.json_error(conn, 401, "invalid_client")
  end

  def introspect_error(conn, %Error{}) do
    json(conn, %{active: false})
  end
end
