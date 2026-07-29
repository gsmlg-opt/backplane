defmodule Backplane.Api.Auth.DiscoveryControllerTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Auth.Resources
  alias Backplane.WebOrigins

  setup %{conn: conn} do
    previous_api_url = Application.get_env(:backplane, :api_url)
    Application.put_env(:backplane, :api_url, "https://metadata.example.test:9443")

    on_exit(fn -> restore_env(:backplane, :api_url, previous_api_url) end)

    conn = %{conn | host: "request-host.invalid", port: 8443, scheme: :https}
    %{conn: conn}
  end

  test "publishes OIDC discovery metadata for the canonical API issuer", %{conn: conn} do
    body =
      conn
      |> get("/.well-known/openid-configuration")
      |> json_response(200)

    assert body ==
             authorization_server_metadata()
             |> Map.merge(%{
               "userinfo_endpoint" => WebOrigins.api_url("/oauth/userinfo"),
               "subject_types_supported" => ["public"],
               "id_token_signing_alg_values_supported" => ["RS256"]
             })

    refute_unsupported_authorization_server_fields(body)
  end

  test "publishes OAuth authorization-server metadata for the canonical API issuer", %{
    conn: conn
  } do
    body =
      conn
      |> get("/.well-known/oauth-authorization-server")
      |> json_response(200)

    assert body == authorization_server_metadata()
    refute_unsupported_authorization_server_fields(body)
  end

  test "publishes MCP protected-resource metadata", %{conn: conn} do
    body =
      conn
      |> get("/.well-known/oauth-protected-resource/mcp")
      |> json_response(200)

    assert body == %{
             "resource" => Resources.uri(:mcp),
             "authorization_servers" => [WebOrigins.api_base_url()],
             "bearer_methods_supported" => ["header"],
             "resource_name" => "Backplane MCP Hub",
             "resource_documentation" => Resources.documentation_uri(:mcp)
           }

    refute Map.has_key?(body, "scopes_supported")
  end

  test "publishes LLM API protected-resource metadata", %{conn: conn} do
    body =
      conn
      |> get("/.well-known/oauth-protected-resource/v1")
      |> json_response(200)

    assert body == %{
             "resource" => Resources.uri(:v1),
             "authorization_servers" => [WebOrigins.api_base_url()],
             "bearer_methods_supported" => ["header"],
             "resource_name" => "Backplane LLM API",
             "resource_documentation" => Resources.documentation_uri(:v1),
             "scopes_supported" => ["llm::models", "llm::invoke"]
           }
  end

  test "does not publish metadata for unknown or non-canonical resource paths", %{conn: conn} do
    for path <- [
          "/.well-known/oauth-protected-resource/unknown",
          "/.well-known/oauth-protected-resource",
          "/.well-known/mcp"
        ] do
      assert conn |> recycle() |> get(path) |> response(404)
    end
  end

  defp authorization_server_metadata do
    %{
      "issuer" => WebOrigins.api_base_url(),
      "authorization_endpoint" => WebOrigins.api_url("/oauth/authorize"),
      "token_endpoint" => WebOrigins.api_url("/oauth/token"),
      "jwks_uri" => WebOrigins.api_url("/oauth/jwks"),
      "introspection_endpoint" => WebOrigins.api_url("/oauth/introspect"),
      "revocation_endpoint" => WebOrigins.api_url("/oauth/revoke"),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "token_endpoint_auth_methods_supported" => [
        "client_secret_basic",
        "client_secret_post",
        "none"
      ],
      "protected_resources" => Enum.map(Resources.keys(), &Resources.uri/1),
      "code_challenge_methods_supported" => ["S256"]
    }
  end

  defp refute_unsupported_authorization_server_fields(body) do
    for field <- [
          "scopes_supported",
          "registration_endpoint",
          "client_id_metadata_document_supported"
        ] do
      refute Map.has_key?(body, field)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
