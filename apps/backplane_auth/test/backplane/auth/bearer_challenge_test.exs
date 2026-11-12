defmodule Backplane.Auth.BearerChallengeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Backplane.Auth.{BearerChallenge, Metadata, Resources}

  test "endpoint keys always carry resource_metadata regardless of request path" do
    key = {:endpoint, "chatgpt", :mcp}

    header =
      :post
      |> conn("/endpoints/chatgpt/mcp/other?x=1")
      |> BearerChallenge.put(key, error: "invalid_token")
      |> Plug.Conn.get_resp_header("www-authenticate")
      |> hd()

    assert header =~ ~s(resource_metadata="#{Resources.metadata_uri(key)}")
    assert header =~ "/endpoints/chatgpt/mcp"
  end

  test "endpoint protected resource metadata" do
    meta = Metadata.protected_resource({:endpoint, "chatgpt", :v1})
    assert meta.resource == Resources.uri({:endpoint, "chatgpt", :v1})
    assert meta.resource_name == "Backplane endpoint chatgpt (LLM API)"
    assert meta.scopes_supported == ["llm::models", "llm::invoke", "llm::manage"]

    assert Metadata.protected_resource({:endpoint, "c", :mcp}).resource_name ==
             "Backplane endpoint c (MCP)"
  end
end
