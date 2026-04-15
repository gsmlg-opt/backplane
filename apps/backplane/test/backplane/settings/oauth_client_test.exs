defmodule Backplane.Settings.OAuthClientTest do
  use ExUnit.Case, async: true

  alias Backplane.Settings.OAuthClient

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.TokenEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn ->
      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
    %{port: port}
  end

  defmodule TokenEndpoint do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
    plug :dispatch

    post "/token" do
      if conn.body_params["client_secret"] == "valid-secret" do
        resp = %{
          "access_token" => "tok-abc",
          "token_type" => "bearer",
          "expires_in" => 3600
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(resp))
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "invalid_client"}))
      end
    end

    post "/token-no-expiry" do
      resp = %{"access_token" => "tok-no-exp", "token_type" => "bearer"}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    post "/token-with-scope" do
      scope = conn.body_params["scope"]

      resp = %{
        "access_token" => "tok-scoped-#{scope}",
        "token_type" => "bearer",
        "expires_in" => 1800
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  describe "exchange/1" do
    test "returns {:ok, token, expires_in} on successful 200", %{port: port} do
      params = %{
        "client_id" => "test-client",
        "client_secret" => "valid-secret",
        "token_url" => "http://localhost:#{port}/token"
      }

      assert {:ok, "tok-abc", 3600} = OAuthClient.exchange(params)
    end

    test "defaults expires_in to 3600 when missing from response", %{port: port} do
      params = %{
        "client_id" => "test-client",
        "client_secret" => "valid-secret",
        "token_url" => "http://localhost:#{port}/token-no-expiry"
      }

      assert {:ok, "tok-no-exp", 3600} = OAuthClient.exchange(params)
    end

    test "includes scope when provided", %{port: port} do
      params = %{
        "client_id" => "test-client",
        "client_secret" => "valid-secret",
        "token_url" => "http://localhost:#{port}/token-with-scope",
        "scope" => "read"
      }

      assert {:ok, "tok-scoped-read", 1800} = OAuthClient.exchange(params)
    end

    test "returns error on 401", %{port: port} do
      params = %{
        "client_id" => "test-client",
        "client_secret" => "wrong-secret",
        "token_url" => "http://localhost:#{port}/token"
      }

      assert {:error, {:token_exchange_failed, 401}} = OAuthClient.exchange(params)
    end

    test "returns error on connection failure" do
      params = %{
        "client_id" => "test-client",
        "client_secret" => "secret",
        "token_url" => "http://localhost:1/token"
      }

      assert {:error, {:token_exchange_error, _}} = OAuthClient.exchange(params)
    end
  end
end
