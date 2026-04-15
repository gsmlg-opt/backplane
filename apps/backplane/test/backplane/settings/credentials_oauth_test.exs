defmodule Backplane.Settings.CredentialsOAuthTest do
  use Backplane.DataCase, async: false

  alias Backplane.Settings.{Credentials, TokenCache}

  setup do
    TokenCache.clear()
    :ok
  end

  describe "store/4 OAuth2 validation" do
    test "rejects oauth2 without client_id" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "token_url" => "https://auth.example.com/token"
      }

      assert {:error, :missing_client_id} = Credentials.store("bad-oauth", "secret", "llm", meta)
    end

    test "rejects oauth2 without token_url" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => "my-client"
      }

      assert {:error, :missing_token_url} = Credentials.store("bad-oauth2", "secret", "llm", meta)
    end

    test "rejects oauth2 with http:// token_url (non-localhost)" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => "c",
        "token_url" => "http://auth.example.com/token"
      }

      assert {:error, :insecure_token_url} = Credentials.store("bad-oauth3", "secret", "llm", meta)
    end

    test "accepts oauth2 with http://localhost token_url" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => "c",
        "token_url" => "http://localhost:8080/token"
      }

      assert {:ok, _} = Credentials.store("local-oauth", "secret", "llm", meta)
    end

    test "creates oauth2 credential with valid metadata" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => "my-client",
        "token_url" => "https://auth.example.com/token",
        "scope" => "read write"
      }

      assert {:ok, cred} = Credentials.store("my-oauth", "client-secret", "llm", meta)
      assert cred.metadata["auth_type"] == "oauth2_client_credentials"
      assert cred.metadata["client_id"] == "my-client"
    end

    test "non-oauth2 credentials pass validation" do
      assert {:ok, _} = Credentials.store("plain-key", "sk-123", "llm")
      assert {:ok, _} = Credentials.store("with-meta", "sk-456", "llm", %{"some" => "data"})
    end
  end

  describe "rotate/2 token cache invalidation" do
    test "invalidates token cache for oauth2 credential" do
      meta = %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => "c",
        "token_url" => "http://localhost:9999/token"
      }

      {:ok, _} = Credentials.store("rot-oauth", "old-secret", "llm", meta)

      # Manually put a token in cache
      TokenCache.put("rot-oauth", "cached-token", 3600)
      assert {:ok, "cached-token"} = TokenCache.get("rot-oauth")

      # Rotate
      {:ok, _} = Credentials.rotate("rot-oauth", "new-secret")

      # Cache should be invalidated
      assert :miss = TokenCache.get("rot-oauth")
    end
  end

  describe "delete/1 token cache invalidation" do
    test "invalidates token cache on delete" do
      {:ok, _} = Credentials.store("del-cache", "secret", "llm")
      TokenCache.put("del-cache", "cached-tok", 3600)

      :ok = Credentials.delete("del-cache")
      assert :miss = TokenCache.get("del-cache")
    end
  end

  describe "invalidate_token/1" do
    test "removes cached token" do
      TokenCache.put("inv-test", "tok", 3600)
      assert {:ok, "tok"} = TokenCache.get("inv-test")

      Credentials.invalidate_token("inv-test")
      assert :miss = TokenCache.get("inv-test")
    end
  end
end
