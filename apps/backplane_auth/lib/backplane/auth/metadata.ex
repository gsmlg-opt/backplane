defmodule Backplane.Auth.Metadata do
  @moduledoc """
  Builds OAuth and OpenID Connect metadata for Backplane's public API origin.
  """

  alias Backplane.Auth.Resources
  alias Backplane.WebOrigins

  @spec authorization_server() :: map()
  def authorization_server do
    %{
      issuer: WebOrigins.api_base_url(),
      authorization_endpoint: WebOrigins.api_url("/oauth/authorize"),
      token_endpoint: WebOrigins.api_url("/oauth/token"),
      jwks_uri: WebOrigins.api_url("/oauth/jwks"),
      introspection_endpoint: WebOrigins.api_url("/oauth/introspect"),
      revocation_endpoint: WebOrigins.api_url("/oauth/revoke"),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
        "none"
      ],
      protected_resources: Enum.map(Resources.keys(), &Resources.uri/1),
      code_challenge_methods_supported: ["S256"]
    }
  end

  @spec openid_configuration() :: map()
  def openid_configuration do
    authorization_server()
    |> Map.merge(%{
      userinfo_endpoint: WebOrigins.api_url("/oauth/userinfo"),
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"]
    })
  end

  @spec protected_resource(Resources.key()) :: map()
  def protected_resource(:mcp) do
    protected_resource_metadata(:mcp, "Backplane MCP Hub")
  end

  def protected_resource(:v1) do
    :v1
    |> protected_resource_metadata("Backplane LLM API")
    |> Map.put(:scopes_supported, ["llm::models", "llm::invoke"])
  end

  defp protected_resource_metadata(resource, name) do
    %{
      resource: Resources.uri(resource),
      authorization_servers: [WebOrigins.api_base_url()],
      bearer_methods_supported: ["header"],
      resource_name: name,
      resource_documentation: Resources.documentation_uri(resource)
    }
  end
end
