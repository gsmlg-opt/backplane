defprotocol Backplane.Oauth.Scope.Authorize do
  @moduledoc false

  def authorized_scopes(schema, scope, public_scopes)
end

defimpl Backplane.Oauth.Scope.Authorize, for: List do
  import Backplane.Oauth.Config, only: [resource_owners: 0]

  alias Backplane.Oauth.ResourceOwner

  def authorized_scopes(authorized_scopes, scopes, _public_scopes) do
    # intersection
    scopes -- (scopes -- authorized_scopes)
  end
end

defimpl Backplane.Oauth.Scope.Authorize, for: Backplane.Oauth.ResourceOwner do
  import Backplane.Oauth.Config, only: [resource_owners: 0]

  alias Backplane.Oauth.ResourceOwner

  def authorized_scopes(%ResourceOwner{} = resource_owner, scopes, _public_scopes) do
    authorized_scopes =
      Enum.map(resource_owners().authorized_scopes(resource_owner), fn e -> e.name end)

    # intersection
    scopes -- (scopes -- authorized_scopes)
  end
end

defimpl Backplane.Oauth.Scope.Authorize, for: Backplane.Oauth.Client do
  alias Backplane.Oauth.ClientsAdapter
  alias Backplane.Oauth.Client
  alias Backplane.Oauth.Scope

  def authorized_scopes(client, scope, public_scopes)

  def authorized_scopes(%Client{authorize_scope: false}, scopes, public_scopes) do
    # intersection
    scopes -- (scopes -- public_scopes)
  end

  def authorized_scopes(%Client{authorize_scope: true} = client, scopes, _public_scopes) do
    authorized_scopes =
      Enum.map(
        ClientsAdapter.authorized_scopes(client),
        fn %Scope{name: name} -> name end
      )

    # intersection
    scopes -- (scopes -- authorized_scopes)
  end
end

defimpl Backplane.Oauth.Scope.Authorize, for: Backplane.Oauth.Token do
  alias Backplane.Oauth.Scope
  alias Backplane.Oauth.Token

  def authorized_scopes(%Token{scope: token_scope}, scopes, _public_scopes) do
    authorized_scopes = Scope.split(token_scope)

    # intersection
    scopes -- (scopes -- authorized_scopes)
  end
end
