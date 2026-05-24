defmodule Backplane.LLM.ApiRouterTest do
  use Backplane.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{ApiRouter, ModelAlias, Provider}
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("anthropic-api-key", "sk-ant-test-key-abcd", "llm")
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok
  end

  @provider_attrs %{
    name: "anthropic-prod",
    credential: "anthropic-api-key"
  }

  defp api_request(method, path, body \\ nil) do
    conn = if body, do: conn(method, path, Jason.encode!(body)), else: conn(method, path, "")
    conn = put_req_header(conn, "content-type", "application/json")
    ApiRouter.call(conn, ApiRouter.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /providers" do
    test "creates a provider and returns 201 with credential_hint" do
      conn =
        api_request(:post, "/providers", %{
          name: "anthropic-prod",
          credential: "anthropic-api-key"
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["name"] == "anthropic-prod"
      assert body["credential"] == "anthropic-api-key"
      assert body["credential_hint"] =~ ~r/^\.\.\./
      assert body["apis"] == []
      assert body["models"] == []
      refute Map.has_key?(body, "api_key")
      refute Map.has_key?(body, "api_key_hint")
    end

    test "returns 422 with errors for invalid provider" do
      conn =
        api_request(:post, "/providers", %{
          name: "anthropic-prod"
        })

      assert conn.status == 422
      body = json_body(conn)
      assert Map.has_key?(body, "errors")
    end
  end

  describe "GET /providers" do
    test "lists active providers" do
      {:ok, _provider} = Provider.create(@provider_attrs)
      {:ok, _alias} = ModelAlias.put("coding", "smart")

      conn = api_request(:get, "/providers")

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body)
      assert length(body) == 1
      [provider] = body
      assert provider["name"] == "anthropic-prod"
      assert provider["credential_hint"] =~ ~r/^\.\.\./
      refute Map.has_key?(provider, "aliases")
    end
  end

  describe "PATCH /providers/:id" do
    test "updates provider fields and returns 200" do
      {:ok, provider} = Provider.create(@provider_attrs)

      conn =
        api_request(:patch, "/providers/#{provider.id}", %{
          rpm_limit: 500
        })

      assert conn.status == 200
      body = json_body(conn)
      assert body["rpm_limit"] == 500
    end
  end

  describe "DELETE /providers/:id" do
    test "soft-deletes provider and returns 200" do
      {:ok, provider} = Provider.create(@provider_attrs)

      conn = api_request(:delete, "/providers/#{provider.id}")

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert Provider.get(provider.id) == nil
    end
  end

  describe "POST /aliases" do
    test "creates custom alias and returns 201" do
      conn =
        api_request(:post, "/aliases", %{
          alias: "coding",
          target: "smart"
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["id"] == "coding"
      assert body["alias"] == "coding"
      assert body["target"] == "smart"
    end

    test "replaces duplicate alias" do
      {:ok, _} = ModelAlias.put("coding", "smart")

      conn =
        api_request(:post, "/aliases", %{
          alias: "coding",
          target: "expert"
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["target"] == "expert"
    end

    test "returns 422 for built-in alias name" do
      conn =
        api_request(:post, "/aliases", %{
          alias: "smart",
          target: "expert"
        })

      assert conn.status == 422
      body = json_body(conn)
      assert Map.has_key?(body, "errors")
    end
  end

  describe "GET /aliases" do
    test "lists all aliases" do
      {:ok, _} = ModelAlias.put("coding", "smart")
      {:ok, _} = ModelAlias.put("mini", "gpt-4o-mini")

      conn = api_request(:get, "/aliases")

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body)
      aliases = Enum.map(body, & &1["alias"])
      assert "coding" in aliases
      assert "mini" in aliases
    end
  end

  describe "DELETE /aliases/:id" do
    test "deletes alias by alias name and returns 200" do
      {:ok, _model_alias} = ModelAlias.put("to-delete", "smart")

      conn = api_request(:delete, "/aliases/to-delete")

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert ModelAlias.list() == []
    end
  end
end
