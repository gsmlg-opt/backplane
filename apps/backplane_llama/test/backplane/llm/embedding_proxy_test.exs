defmodule Backplane.LLM.EmbeddingProxyTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.{Clients, Embedding}
  alias Backplane.LLM.ProxyPlug
  alias Backplane.Settings.Credentials

  setup do
    assert {:ok, client, token} =
             Clients.issue_client(%{
               name: "embedding-resource-client",
               scopes: ["llm::invoke"],
               active: true
             })

    {:ok, _} = Credentials.store("embedding-route-credential", "embedding-upstream-token", "llm")
    %{client: client, token: token}
  end

  for {base_path, upstream_path} <- [
        {"", "/v1/embeddings"},
        {"/v1", "/v1/embeddings"},
        {"/api/v1", "/api/v1/embeddings"}
      ] do
    @base_path base_path
    @upstream_path upstream_path

    test "authenticated embeddings preserve routing and body with base path #{base_path}", %{
      client: client,
      token: token
    } do
      bypass = Bypass.open()

      {:ok, %{provider: embedding_provider, model: model}} =
        Embedding.create_provider_with_model(%{
          "name" => "embedding-route",
          "credential" => "embedding-route-credential",
          "base_url" => "http://localhost:#{bypass.port}" <> @base_path,
          "enabled" => true,
          "model" => "openai/text-embedding-3-large",
          "model_enabled" => true,
          "metadata" => ~s({"dimensions":2560})
        })

      Bypass.expect_once(bypass, "POST", @upstream_path, fn upstream ->
        {:ok, body, upstream} = read_body(upstream)

        assert Jason.decode!(body) == %{
                 "model" => "openai/text-embedding-3-large",
                 "input" => ["captured evidence"],
                 "dimensions" => 2560,
                 "encoding_format" => "float"
               }

        assert get_req_header(upstream, "authorization") == ["Bearer embedding-upstream-token"]
        assert get_req_header(upstream, "x-api-key") == []

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [%{"index" => 0, "embedding" => List.duplicate(0.1, 2560)}]
          })
        )
      end)

      request =
        Jason.encode!(%{
          model: Embedding.model_id(%{model | provider: embedding_provider}),
          input: ["captured evidence"],
          dimensions: 2560,
          encoding_format: "float"
        })

      conn =
        conn(:post, "/v1/embeddings", request)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> ProxyPlug.call(ProxyPlug.init([]))

      assert conn.status == 200
      assert conn.assigns.resource_auth.kind == :client_token
      assert conn.assigns.resource_auth.client_id == client.id
      assert conn.assigns.resource_auth.scopes == ["llm::invoke"]
      assert length(hd(Jason.decode!(conn.resp_body)["data"])["embedding"]) == 2560
    end
  end
end
