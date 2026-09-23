defmodule Backplane.LLM.ResourceAuthorizationTest do
  use BackplaneLlama.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.ResourceAuthorization

  test "maps routes to their least operation scope" do
    assert ResourceAuthorization.required_scope(conn(:get, "/v1")) == nil
    assert ResourceAuthorization.required_scope(conn(:get, "/v1/models")) == "llm::models"

    assert ResourceAuthorization.required_scope(conn(:get, "/v1/providers/openai-codex/models")) ==
             "llm::models"

    assert ResourceAuthorization.required_scope(conn(:post, "/v1/responses")) == "llm::invoke"
    assert ResourceAuthorization.required_scope(conn(:post, "/v1/messages")) == "llm::invoke"
    assert ResourceAuthorization.required_scope(conn(:get, "/v1beta/models")) == "llm::models"

    assert ResourceAuthorization.required_scope(
             conn(:post, "/v1beta/models/gemini:generateContent")
           ) == "llm::invoke"

    for rpc <- ["loadCodeAssist", "fetchAvailableModels"] do
      assert ResourceAuthorization.required_scope(
               conn(:post, "/antigravity/providers/account/v1internal:#{rpc}")
             ) == "llm::models"
    end

    assert ResourceAuthorization.required_scope(
             conn(:post, "/antigravity/providers/account/v1internal:onboardUser")
           ) == "llm::manage"

    for rpc <- ["generateContent", "streamGenerateContent"] do
      assert ResourceAuthorization.required_scope(
               conn(:post, "/antigravity/providers/account/v1internal:#{rpc}")
             ) == "llm::invoke"
    end

    assert ResourceAuthorization.required_scope(conn(:get, "/v1/unknown")) == nil
  end

  test "requires model scope for provider-scoped model discovery" do
    conn = authorize(:get, "/v1/providers/openai-codex/models", :oauth, ["llm::invoke"])

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "insufficient_scope"}
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

  test "database clients enforce operation scopes while legacy and open remain unrestricted" do
    denied = authorize(:post, "/v1/responses", :client_token, ["llm::models"])
    assert denied.halted
    assert denied.status == 403

    allowed = authorize(:post, "/v1/responses", :client_token, ["llm::invoke"])
    refute allowed.halted

    for kind <- [:legacy, :open] do
      conn = authorize(:post, "/v1/responses", kind, [])

      refute conn.halted
      assert conn.status == nil
    end
  end

  test "Google scope failures use a native error envelope" do
    conn = authorize(:get, "/v1beta/models", :client_token, ["llm::invoke"])
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["status"] == "PERMISSION_DENIED"
  end

  test "Antigravity enforces least privilege for both OAuth and database clients" do
    for kind <- [:oauth, :client_token],
        {rpc, required} <- [
          {"loadCodeAssist", "llm::models"},
          {"fetchAvailableModels", "llm::models"},
          {"onboardUser", "llm::manage"},
          {"generateContent", "llm::invoke"},
          {"streamGenerateContent", "llm::invoke"}
        ] do
      path = "/antigravity/providers/account/v1internal:#{rpc}"

      for granted <- ["llm::models", "llm::invoke", "llm::manage", "llm::*"] do
        result = authorize(:post, path, kind, [granted])

        if granted in [required, "llm::*"] do
          refute result.halted
        else
          assert result.status == 403
          assert Jason.decode!(result.resp_body)["error"]["status"] == "PERMISSION_DENIED"
        end
      end
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
