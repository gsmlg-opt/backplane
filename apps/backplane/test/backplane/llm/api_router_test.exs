defmodule Backplane.LLM.ApiRouterTest do
  use Backplane.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{ApiRouter, ModelAlias, Provider}
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("anthropic-api-key", "sk-ant-test-key-abcd", "llm")
    :ok
  end

  @provider_attrs %{
    name: "anthropic-prod",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "anthropic-api-key",
    models: ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001"]
  }

  defp api_request(method, path, body \\ nil) do
    conn = if body, do: conn(method, path, Jason.encode!(body)), else: conn(method, path, "")
    conn = put_req_header(conn, "content-type", "application/json")
    ApiRouter.call(conn, ApiRouter.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # ── POST /providers ──────────────────────────────────────────────────────────

  describe "POST /providers" do
    test "creates a provider and returns 201 with credential_hint" do
      conn =
        api_request(:post, "/providers", %{
          name: "anthropic-prod",
          api_type: "anthropic",
          api_url: "https://api.anthropic.com",
          credential: "anthropic-api-key",
          models: ["claude-sonnet-4-20250514"]
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["name"] == "anthropic-prod"
      assert body["api_type"] == "anthropic"
      assert body["credential"] == "anthropic-api-key"
      assert body["credential_hint"] =~ ~r/^\.\.\./
      refute Map.has_key?(body, "api_key")
      refute Map.has_key?(body, "api_key_hint")
    end

    test "returns 422 with errors for invalid provider" do
      conn =
        api_request(:post, "/providers", %{
          name: "anthropic-prod",
          api_type: "anthropic",
          api_url: "https://api.anthropic.com"
          # missing credential and models
        })

      assert conn.status == 422
      body = json_body(conn)
      assert Map.has_key?(body, "errors")
    end
  end

  # ── GET /providers ───────────────────────────────────────────────────────────

  describe "GET /providers" do
    test "lists active providers with aliases" do
      {:ok, provider} = Provider.create(@provider_attrs)

      {:ok, _alias} =
        ModelAlias.create(%{
          alias: "fast",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      conn = api_request(:get, "/providers")

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body)
      assert length(body) == 1
      [p] = body
      assert p["name"] == "anthropic-prod"
      assert p["credential_hint"] =~ ~r/^\.\.\./
      assert is_list(p["aliases"])
      assert length(p["aliases"]) == 1
    end
  end

  # ── PATCH /providers/:id ─────────────────────────────────────────────────────

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

  # ── DELETE /providers/:id ────────────────────────────────────────────────────

  describe "DELETE /providers/:id" do
    test "soft-deletes provider and returns 200" do
      {:ok, provider} = Provider.create(@provider_attrs)

      conn = api_request(:delete, "/providers/#{provider.id}")

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true

      # Provider should no longer appear in list
      assert Provider.get(provider.id) == nil
    end
  end

  # ── POST /aliases ─────────────────────────────────────────────────────────────

  describe "POST /aliases" do
    test "creates alias and returns 201" do
      {:ok, provider} = Provider.create(@provider_attrs)

      conn =
        api_request(:post, "/aliases", %{
          alias: "fast",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["alias"] == "fast"
      assert body["model"] == "claude-haiku-4-5-20251001"
      assert body["provider_id"] == provider.id
    end

    test "returns 422 for duplicate alias" do
      {:ok, provider} = Provider.create(@provider_attrs)

      {:ok, _} =
        ModelAlias.create(%{
          alias: "fast",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      conn =
        api_request(:post, "/aliases", %{
          alias: "fast",
          model: "claude-sonnet-4-20250514",
          provider_id: provider.id
        })

      assert conn.status == 422
      body = json_body(conn)
      assert Map.has_key?(body, "errors")
    end
  end

  # ── GET /aliases ─────────────────────────────────────────────────────────────

  describe "GET /aliases" do
    test "lists all aliases" do
      {:ok, provider} = Provider.create(@provider_attrs)

      {:ok, _} =
        ModelAlias.create(%{
          alias: "fast",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      {:ok, _} =
        ModelAlias.create(%{
          alias: "smart",
          model: "claude-sonnet-4-20250514",
          provider_id: provider.id
        })

      conn = api_request(:get, "/aliases")

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body)
      assert length(body) == 2
      aliases = Enum.map(body, & &1["alias"])
      assert "fast" in aliases
      assert "smart" in aliases
    end
  end

  # ── DELETE /aliases/:id ───────────────────────────────────────────────────────

  describe "DELETE /aliases/:id" do
    test "deletes alias and returns 200" do
      {:ok, provider} = Provider.create(@provider_attrs)

      {:ok, model_alias} =
        ModelAlias.create(%{
          alias: "to-delete",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      conn = api_request(:delete, "/aliases/#{model_alias.id}")

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true

      assert ModelAlias.list() == []
    end
  end
end
