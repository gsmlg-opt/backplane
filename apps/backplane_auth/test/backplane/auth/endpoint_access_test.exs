defmodule Backplane.Auth.EndpointAccessTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth.{EndpointAccess, OAuth}
  alias Backplane.Endpoints
  alias Backplane.Oauth.Ecto.Token

  setup do
    {:ok, endpoint} = Endpoints.create(%{name: "chatgpt", mcp_enabled: true, llm_enabled: true})
    %{endpoint: endpoint}
  end

  defp bound_token(resource) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!()
    resource_access_token_fixture!(user, client, ["day::*"], resource)
  end

  test "delete_endpoint revokes bound tokens only and removes the endpoint", %{endpoint: endpoint} do
    mcp = bound_token({:endpoint, "chatgpt", :mcp})
    v1 = bound_token({:endpoint, "chatgpt", :v1})
    other = bound_token(:mcp)

    assert {:ok, _} = EndpointAccess.delete_endpoint(endpoint)

    for t <- [mcp, v1] do
      reloaded = Repo.get!(Token, t.id)
      assert reloaded.revoked_at
      assert reloaded.refresh_token_revoked_at
    end

    refute Repo.get!(Token, other.id).revoked_at
    assert Endpoints.get_by_name("chatgpt") == nil
  end

  test "client_allows_resource? honours endpoint state and client restriction", %{
    endpoint: endpoint
  } do
    allowed = oauth_client_fixture!()
    excluded = oauth_client_fixture!()
    key = {:endpoint, "chatgpt", :mcp}

    for c <- [allowed, excluded] do
      {:ok, _} = OAuth.update_client_resources(OAuth.get_client(c.id), [:mcp, :v1])
    end

    assert OAuth.client_allows_resource?(OAuth.get_client(allowed.id), key)
    assert OAuth.client_allows_resource?(OAuth.get_client(allowed.id), {:endpoint, "chatgpt", :v1})

    {:ok, endpoint} =
      Endpoints.update(endpoint, %{restrict_clients: true, oauth_client_ids: [allowed.id]})

    assert OAuth.client_allows_resource?(OAuth.get_client(allowed.id), key)
    refute OAuth.client_allows_resource?(OAuth.get_client(excluded.id), key)

    {:ok, _} = Endpoints.set_enabled(endpoint, false)
    refute OAuth.client_allows_resource?(OAuth.get_client(allowed.id), key)
  end

  test "client without the base resource is refused" do
    client = oauth_client_fixture!()
    refute OAuth.client_allows_resource?(OAuth.get_client(client.id), {:endpoint, "chatgpt", :mcp})
  end

  test "endpoints always challenge" do
    assert OAuth.enabled_client_for_resource?({:endpoint, "nope", :mcp})
  end
end
