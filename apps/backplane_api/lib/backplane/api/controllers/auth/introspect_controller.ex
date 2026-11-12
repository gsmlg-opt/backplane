defmodule Backplane.Api.Auth.IntrospectController do
  use Backplane.Api, :controller

  @behaviour Backplane.Oauth.IntrospectApplication

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Oauth.Error
  alias Backplane.Oauth.IntrospectResponse

  def introspect(conn, params) do
    case Helpers.check_client_enabled(conn, params) do
      :ok -> Backplane.Oauth.introspect(conn, __MODULE__)
      {:error, :invalid_client} -> Helpers.json_error(conn, 401, "invalid_client")
    end
  end

  @impl Backplane.Oauth.IntrospectApplication
  def introspect_success(conn, %IntrospectResponse{active: true} = response) do
    body = %{
      active: true,
      client_id: response.client_id,
      username: response.username,
      scope: response.scope,
      sub: response.sub,
      iss: response.iss,
      exp: response.exp,
      iat: response.iat
    }

    json(conn, maybe_put_resource_audience(body, response.client_id, conn.params["token"]))
  end

  def introspect_success(conn, %IntrospectResponse{}) do
    json(conn, %{active: false})
  end

  @impl Backplane.Oauth.IntrospectApplication
  def introspect_error(conn, %Error{error: :invalid_client}) do
    Helpers.json_error(conn, 401, "invalid_client")
  end

  def introspect_error(conn, %Error{}) do
    json(conn, %{active: false})
  end

  defp maybe_put_resource_audience(body, client_id, token) do
    case Backplane.Auth.TokenResources.lookup_access_token(client_id, token) do
      {:ok, _token, resource} when not is_nil(resource) ->
        if Backplane.Auth.Resources.oauth_bindable?(resource),
          do: Map.put(body, :aud, Backplane.Auth.Resources.uri(resource)),
          else: body

      _unmapped ->
        body
    end
  end
end
