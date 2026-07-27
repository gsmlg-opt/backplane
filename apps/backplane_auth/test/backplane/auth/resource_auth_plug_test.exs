defmodule Backplane.Auth.ResourceAuthPlugTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures
  import Plug.Conn
  import Plug.Test

  alias Backplane.Auth.{BearerChallenge, ResourceAuthPlug, Resources}
  alias Backplane.Clients

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)

    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

    on_exit(fn ->
      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
    end)

    :ok
  end

  test "authenticates a resource OAuth token without assigning a PAT client" do
    token = oauth_token!(:mcp, ["github::*"])

    conn =
      :post
      |> conn("/mcp")
      |> bearer(token.value)
      |> authenticate(:mcp)

    assert conn.status == nil

    assert conn.assigns.resource_auth == %{
             kind: :oauth,
             subject: token.sub,
             client_id: token.client_id,
             resource: :mcp,
             scopes: ["github::*"]
           }

    assert conn.assigns.tool_scopes == ["github::*"]
    refute Map.has_key?(conn.assigns, :client)
  end

  test "authenticates an active PAT and preserves its MCP assignments" do
    {client, token} = pat_fixture!(scopes: ["github::read"])

    conn =
      :post
      |> conn("/mcp")
      |> bearer(token)
      |> authenticate(:mcp)

    assert conn.status == nil
    assert conn.assigns.client.id == client.id
    assert conn.assigns.tool_scopes == ["github::read"]

    assert conn.assigns.resource_auth == %{
             kind: :client_token,
             subject: nil,
             client_id: client.id,
             resource: :mcp,
             scopes: ["github::read"]
           }
  end

  test "authenticates the configured legacy token" do
    Application.put_env(:backplane, :auth_token, "legacy-secret")

    conn =
      :post
      |> conn("/mcp")
      |> bearer("legacy-secret")
      |> authenticate(:mcp)

    assert conn.assigns.resource_auth == %{
             kind: :legacy,
             subject: nil,
             client_id: nil,
             resource: :mcp,
             scopes: ["*"]
           }

    assert conn.assigns.tool_scopes == ["*"]
    refute Map.has_key?(conn.assigns, :client)
  end

  test "uses open mode only when no authentication method is configured" do
    conn = conn(:post, "/mcp") |> authenticate(:mcp)

    assert conn.assigns.resource_auth == %{
             kind: :open,
             subject: nil,
             client_id: nil,
             resource: :mcp,
             scopes: ["*"]
           }

    assert conn.assigns.tool_scopes == ["*"]
  end

  test "does not fall through after a Backplane-signed wrong-audience token" do
    user = auth_user_fixture!()

    client =
      oauth_client_fixture!(
        resources: [:mcp, :v1],
        scopes: ["github::*", "llm::invoke"]
      )

    token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)
    Application.put_env(:backplane, :auth_token, token.value)

    conn =
      :post
      |> conn("/mcp")
      |> bearer(token.value)
      |> authenticate(:mcp)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ ~s(resource_metadata="#{Resources.metadata_uri(:mcp)}")
    refute conn.assigns[:resource_auth]
  end

  test "rejects a supplied invalid bearer even when the resource is otherwise open" do
    conn =
      :get
      |> conn("/v1")
      |> bearer("unknown")
      |> authenticate(:v1)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    assert get_resp_header(conn, "www-authenticate") == []
    refute conn.assigns[:resource_auth]
  end

  test "rejects malformed, empty, and multiple authorization headers" do
    for headers <- [
          ["Basic abc"],
          ["Bearer"],
          ["Bearer   "],
          ["Bearer first", "Bearer second"]
        ] do
      conn =
        Enum.reduce(headers, conn(:post, "/mcp"), fn header, conn ->
          prepend_req_headers(conn, [{"authorization", header}])
        end)
        |> authenticate(:mcp)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
      refute conn.assigns[:resource_auth]
    end
  end

  test "an enabled OAuth client activates an exact canonical metadata challenge" do
    oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])

    conn = conn(:post, "/mcp") |> authenticate(:mcp)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"

    assert get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer resource_metadata="#{Resources.metadata_uri(:mcp)}")
           ]
  end

  test "query-bearing and noncanonical requests omit resource metadata" do
    oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])

    for path <- ["/mcp?x=1", "/nested/mcp"] do
      conn = conn(:post, path) |> authenticate(:mcp)

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      refute challenge =~ "resource_metadata"
    end
  end

  test "PAT-only protection preserves the existing unauthorized response" do
    pat_fixture!()

    conn = conn(:post, "/mcp") |> authenticate(:mcp)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "an inactive-only PAT row activates protection but never authenticates" do
    {_client, token} = pat_fixture!(active: false)

    missing = conn(:post, "/mcp") |> authenticate(:mcp)
    invalid = conn(:post, "/mcp") |> bearer(token) |> authenticate(:mcp)

    for conn <- [missing, invalid] do
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
      refute conn.assigns[:resource_auth]
    end
  end

  test "a non-empty legacy token list takes precedence over the single token" do
    Application.put_env(:backplane, :auth_token, "single-token")
    Application.put_env(:backplane, :auth_tokens, ["new-token", "old-token"])

    rejected =
      conn(:post, "/mcp")
      |> bearer("single-token")
      |> authenticate(:mcp)

    accepted =
      conn(:post, "/mcp")
      |> bearer("old-token")
      |> authenticate(:mcp)

    assert rejected.status == 401
    assert accepted.assigns.resource_auth.kind == :legacy
  end

  test "an empty or non-list legacy token list falls back to the single token" do
    Application.put_env(:backplane, :auth_token, "single-token")

    for tokens <- [[], "not-a-list", nil] do
      Application.put_env(:backplane, :auth_tokens, tokens)

      conn =
        conn(:post, "/mcp")
        |> bearer("single-token")
        |> authenticate(:mcp)

      assert conn.assigns.resource_auth.kind == :legacy
    end
  end

  test "required_scope decorates OAuth challenges but does not authorize" do
    oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])

    opts =
      ResourceAuthPlug.init(
        resource: :v1,
        required_scope: {__MODULE__, :required_scope, ["models"]}
      )

    missing = ResourceAuthPlug.call(conn(:get, "/v1/models"), opts)

    assert get_resp_header(missing, "www-authenticate") == [
             ~s(Bearer scope="llm::models")
           ]

    token = oauth_token!(:v1, ["llm::invoke"])

    authenticated =
      conn(:get, "/v1/models")
      |> bearer(token.value)
      |> ResourceAuthPlug.call(opts)

    assert authenticated.status == nil
    assert authenticated.assigns.resource_auth.scopes == ["llm::invoke"]
  end

  test "invalid opaque credentials use OAuth errors when OAuth is enabled" do
    oauth_client_fixture!(resources: [:v1], scopes: ["llm::models"])

    conn =
      :get
      |> conn("/v1")
      |> bearer("opaque-invalid")
      |> authenticate(:v1)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ ~s(resource_metadata="#{Resources.metadata_uri(:v1)}")
  end

  test "serializes challenge fields in stable order and escapes quoted values" do
    oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])

    conn =
      conn(:post, "/mcp")
      |> BearerChallenge.put(:mcp, error: ~s(bad"\\value), scope: ~s(tool"\\scope))

    assert get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer error="bad\\"\\\\value", scope="tool\\"\\\\scope", resource_metadata="#{Resources.metadata_uri(:mcp)}")
           ]
  end

  test "never derives metadata links from request host headers" do
    oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])

    conn =
      %{conn(:post, "/mcp") | host: "attacker.example"}
      |> authenticate(:mcp)

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ Resources.metadata_uri(:mcp)
    refute challenge =~ "attacker.example"
  end

  def required_scope(_conn, suffix), do: "llm::" <> suffix

  defp authenticate(conn, resource) do
    ResourceAuthPlug.call(conn, ResourceAuthPlug.init(resource: resource))
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp oauth_token!(resource, scopes) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [resource], scopes: scopes)
    resource_access_token_fixture!(user, client, scopes, resource)
  end

  defp pat_fixture!(attrs \\ []) do
    token = Keyword.get(attrs, :token, "pat-#{System.unique_integer([:positive])}")

    {:ok, client} =
      Clients.create_client(%{
        name: "PAT #{System.unique_integer([:positive])}",
        token: token,
        scopes: Keyword.get(attrs, :scopes, ["*"]),
        active: Keyword.get(attrs, :active, true)
      })

    {client, token}
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
