defmodule Backplane.Settings.OAuthRefresherTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.OAuthRefresher

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.MockEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(:backplane, OAuthRefresher,
      anthropic_token_url: "http://localhost:#{port}/anthropic/token",
      openai_token_url: "http://localhost:#{port}/openai/token",
      google_token_url: "http://localhost:#{port}/google/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port}
  end

  defmodule MockEndpoint do
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
    plug(:dispatch)

    post "/anthropic/token" do
      cond do
        conn.body_params["refresh_token"] == "good-anthropic" ->
          resp = %{
            "access_token" => "ant-new-access",
            "refresh_token" => "ant-new-refresh",
            "expires_in" => 28_800,
            "token_type" => "Bearer",
            "scope" => "user:inference"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end

    post "/openai/token" do
      cond do
        conn.body_params["refresh_token"] == "good-openai" ->
          resp = %{
            "access_token" => "oai-new-access",
            "refresh_token" => "oai-new-refresh",
            "id_token" => "oai-new-id",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end

    post "/google/token" do
      cond do
        conn.body_params["refresh_token"] == "good-google" and
          conn.body_params["client_id"] == "test-google-client" and
            conn.body_params["client_secret"] == "test-google-secret" ->
          resp = %{
            "access_token" => "goog-new-access",
            "refresh_token" => "goog-new-refresh",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  describe "refresh/2 :anthropic_oauth" do
    test "returns rotated tokens on success" do
      assert {:ok,
              %{
                access_token: "ant-new-access",
                refresh_token: "ant-new-refresh",
                expires_at: expires_at
              }} =
               OAuthRefresher.refresh(:anthropic_oauth, "good-anthropic")

      now_ms = System.system_time(:millisecond)
      assert expires_at > now_ms
      assert_in_delta expires_at, now_ms + 28_800 * 1000, 5_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:anthropic_oauth, "wrong")
    end
  end

  describe "refresh/2 :openai_oauth" do
    test "returns rotated tokens with id_token on success" do
      assert {:ok,
              %{
                access_token: "oai-new-access",
                refresh_token: "oai-new-refresh",
                id_token: "oai-new-id",
                expires_at: expires_at
              }} =
               OAuthRefresher.refresh(:openai_oauth, "good-openai")

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3600 * 1000, 5_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:openai_oauth, "wrong")
    end
  end

  describe "refresh/3 :google_oauth" do
    test "requires configured Google OAuth client credentials" do
      assert {:error, :missing_google_oauth_client_id} =
               OAuthRefresher.refresh(:google_oauth, "good-google")
    end

    test "returns rotated tokens with configured Google OAuth client credentials" do
      assert {:ok,
              %{
                access_token: "goog-new-access",
                refresh_token: "goog-new-refresh",
                expires_at: expires_at
              }} =
               OAuthRefresher.refresh(:google_oauth, "good-google",
                 google_client_id: "test-google-client",
                 google_client_secret: "test-google-secret"
               )

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3600 * 1000, 5_000
    end
  end
end
