defprotocol Backplane.Oauth.Ecto.OauthMapper do
  @moduledoc false

  @spec to_oauth_schema(schema :: struct()) :: oauth_schema :: struct()
  def to_oauth_schema(schema)
end

defimpl Backplane.Oauth.Ecto.OauthMapper, for: Backplane.Oauth.Ecto.Token do
  import Backplane.Oauth.Config, only: [repo: 0, resource_owners: 0, clients: 0]

  alias Backplane.Oauth.Ecto
  alias Backplane.Oauth.Ecto.OauthMapper
  alias Backplane.Oauth

  def to_oauth_schema(%Ecto.Token{} = token) do
    client =
      case clients().get_client(token.client_id) do
        %Oauth.Client{} = client -> client
        _ -> nil
      end

    # token is linked to a resource_owner
    resource_owner =
      token.resource_owner ||
        with "" <> sub <- token.sub,
             {:ok, resource_owner} <- resource_owners().get_by(sub: sub) do
          resource_owner
        else
          _ -> nil
        end

    struct(
      Oauth.Token,
      Map.merge(
        Map.from_struct(token),
        %{
          client: client,
          resource_owner: resource_owner
        }
      )
    )
  end
end

defimpl Backplane.Oauth.Ecto.OauthMapper, for: Backplane.Oauth.Ecto.Client do
  import Backplane.Oauth.Config, only: [repo: 0]

  alias Backplane.Oauth.Ecto
  alias Backplane.Oauth.Ecto.OauthMapper
  alias Backplane.Oauth

  def to_oauth_schema(%Ecto.Client{} = client) do
    client = repo().preload(client, :authorized_scopes)

    struct(
      Oauth.Client,
      Map.merge(
        Map.from_struct(client),
        %{
          authorized_scopes:
            Enum.map(client.authorized_scopes, fn scope ->
              OauthMapper.to_oauth_schema(scope)
            end)
        }
      )
    )
  end
end

defimpl Backplane.Oauth.Ecto.OauthMapper, for: Backplane.Oauth.Ecto.Scope do
  alias Backplane.Oauth.Ecto
  alias Backplane.Oauth

  def to_oauth_schema(%Ecto.Scope{} = scope) do
    struct(Oauth.Scope, Map.from_struct(scope))
  end
end
