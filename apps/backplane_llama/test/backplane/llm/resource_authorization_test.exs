defmodule Backplane.LLM.ResourceAuthorizationTest do
  use Backplane.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.ResourceAuthorization

  test "maps routes to their least operation scope" do
    assert ResourceAuthorization.required_scope(conn(:get, "/v1")) == nil
    assert ResourceAuthorization.required_scope(conn(:get, "/v1/models")) == "llm::models"
    assert ResourceAuthorization.required_scope(conn(:post, "/v1/responses")) == "llm::invoke"
    assert ResourceAuthorization.required_scope(conn(:post, "/v1/messages")) == "llm::invoke"
    assert ResourceAuthorization.required_scope(conn(:get, "/v1/unknown")) == nil
  end

  test "accepts exact and wildcard model scopes" do
    for scopes <- [["llm::models"], ["llm::*"], ["*"]] do
      conn = authorize(:get, "/v1/models", :oauth, scopes)

      refute conn.halted
      assert conn.status == nil
    end
  end

  test "accepts exact and wildcard invocation scopes" do
    for scopes <- [["llm::invoke"], ["llm::*"], ["*"]] do
      conn = authorize(:post, "/v1/responses", :oauth, scopes)

      refute conn.halted
      assert conn.status == nil
    end
  end

  test "keeps model discovery and invocation scopes separate" do
    model_only = authorize(:post, "/v1/responses", :oauth, ["llm::models"])
    invoke_only = authorize(:get, "/v1/models", :oauth, ["llm::invoke"])

    for {conn, scope} <- [
          {model_only, "llm::invoke"},
          {invoke_only, "llm::models"}
        ] do
      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "insufficient_scope"}

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer error="insufficient_scope", scope="#{scope}")
             ]
    end
  end

  test "PAT, legacy, and open assignments bypass operation scopes" do
    for kind <- [:client_token, :legacy, :open] do
      conn = authorize(:post, "/v1/responses", kind, [])

      refute conn.halted
      assert conn.status == nil
    end
  end

  defp authorize(method, path, kind, scopes) do
    method
    |> conn(path)
    |> assign(:resource_auth, %{
      kind: kind,
      subject: nil,
      client_id: nil,
      resource: :v1,
      scopes: scopes
    })
    |> ResourceAuthorization.call(ResourceAuthorization.init([]))
  end
end
