defmodule Backplane.Settings.OAuthRefresherTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.OAuthRefresher

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.MockEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior = Application.get_env(:backplane, OAuthRefresher, [])

    prior_env =
      snapshot_env(
        ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy FIGMA_MCP_CLIENT_ID FIGMA_MCP_CLIENT_SECRET]
      )

    Application.put_env(:backplane, OAuthRefresher,
      anthropic_token_url: "http://localhost:#{port}/anthropic/token",
      openai_token_url: "http://localhost:#{port}/openai/token",
      google_token_url: "http://localhost:#{port}/google/token",
      xai_token_url: "http://localhost:#{port}/xai/token",
      figma_token_url: "http://localhost:#{port}/figma/token",
      figma_mcp_client_id: "test-figma-client",
      figma_mcp_client_secret: "test-figma-secret"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior)
      restore_env(prior_env)

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
        not valid_anthropic_headers?(conn) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{"error" => "missing_claude_code_headers"}))

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

    defp valid_anthropic_headers?(conn) do
      headers = Map.new(conn.req_headers)

      headers["user-agent"] == "claude-cli/2.1.165 (external, cli)" and
        headers["x-app"] == "cli" and
        headers["anthropic-client-platform"] == "claude_code_cli"
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
            valid_google_client_credentials?(conn.body_params) ->
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

    post "/xai/token" do
      cond do
        conn.body_params["refresh_token"] == "good-xai" and valid_xai_body?(conn.body_params) ->
          resp = %{
            "access_token" => "xai-new-access",
            "refresh_token" => "xai-new-refresh",
            "id_token" => "xai-new-id",
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

    post "/figma/token" do
      expected_auth = "Basic " <> Base.encode64("test-figma-client:test-figma-secret")

      valid_request? =
        conn.body_params["grant_type"] == "refresh_token" and
          conn.body_params["resource"] == "https://mcp.figma.com/mcp" and
          get_req_header(conn, "authorization") == [expected_auth]

      case {valid_request?, conn.body_params["refresh_token"]} do
        {true, "good-figma"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "access_token" => "figma-new-access",
              "refresh_token" => "figma-new-refresh",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })
          )

        {true, "keep-figma-refresh"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "access_token" => "figma-new-access",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })
          )

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_request"}))
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp valid_google_client_credentials?(body) do
      (body["client_id"] == "test-google-client" and
         body["client_secret"] == "test-google-secret") or
        (body["client_id"] == Backplane.Settings.OAuthRefresher.google_antigravity_client_id() and
           body["client_secret"] ==
             Backplane.Settings.OAuthRefresher.google_antigravity_client_secret())
    end

    defp valid_xai_body?(body) do
      body["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828"
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

    test "uses HTTP_PROXY for refresh requests when target is not in NO_PROXY", %{port: port} do
      Application.put_env(:backplane, OAuthRefresher,
        openai_token_url: "http://auth.openai.invalid/openai/token"
      )

      System.put_env("HTTP_PROXY", "http://localhost:#{port}")
      System.delete_env("http_proxy")
      System.delete_env("HTTPS_PROXY")
      System.delete_env("https_proxy")
      System.delete_env("ALL_PROXY")
      System.delete_env("all_proxy")
      System.put_env("NO_PROXY", "localhost,127.0.0.1")
      System.put_env("no_proxy", "localhost,127.0.0.1")

      assert {:ok,
              %{
                access_token: "oai-new-access",
                refresh_token: "oai-new-refresh",
                id_token: "oai-new-id"
              }} = OAuthRefresher.refresh(:openai_oauth, "good-openai")
    end

    test "bounds proxy connection and CONNECT tunnel waits" do
      System.put_env("HTTPS_PROXY", "http://proxy.example:3128")
      System.delete_env("https_proxy")
      System.delete_env("NO_PROXY")
      System.delete_env("no_proxy")

      options = OAuthRefresher.request_options("https://auth.openai.invalid/oauth/token")
      connect_options = Keyword.fetch!(options, :connect_options)

      assert {:http, "proxy.example", 3128, proxy_options} =
               Keyword.fetch!(connect_options, :proxy)

      assert Keyword.fetch!(proxy_options, :tunnel_timeout) == 30_000
      assert Keyword.fetch!(proxy_options, :transport_opts)[:timeout] == 30_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:openai_oauth, "wrong")
    end
  end

  describe "refresh/3 :google_oauth" do
    test "uses Antigravity OAuth client credentials by default" do
      assert {:ok,
              %{
                access_token: "goog-new-access",
                refresh_token: "goog-new-refresh",
                expires_at: expires_at
              }} =
               OAuthRefresher.refresh(:google_oauth, "good-google")

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3600 * 1000, 5_000
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

  describe "refresh/2 :xai_oauth" do
    test "returns rotated tokens with id_token on success" do
      assert {:ok,
              %{
                access_token: "xai-new-access",
                refresh_token: "xai-new-refresh",
                id_token: "xai-new-id",
                expires_at: expires_at
              }} =
               OAuthRefresher.refresh(:xai_oauth, "good-xai")

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3600 * 1000, 5_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:xai_oauth, "wrong")
    end
  end

  describe "refresh/2 :figma_oauth" do
    test "uses Basic client authentication and the MCP resource" do
      assert {:ok,
              %{
                access_token: "figma-new-access",
                refresh_token: "figma-new-refresh",
                expires_at: expires_at
              }} = OAuthRefresher.refresh(:figma_oauth, "good-figma")

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3_600_000, 5_000
    end

    test "retains the previous refresh token when Figma does not rotate it" do
      assert {:ok, %{refresh_token: "keep-figma-refresh"}} =
               OAuthRefresher.refresh(:figma_oauth, "keep-figma-refresh")
    end

    test "requires both configured client credentials", %{port: port} do
      configured = Application.get_env(:backplane, OAuthRefresher, [])
      System.delete_env("FIGMA_MCP_CLIENT_ID")
      System.delete_env("FIGMA_MCP_CLIENT_SECRET")

      Application.put_env(:backplane, OAuthRefresher,
        figma_token_url: "http://localhost:#{port}/figma/token"
      )

      assert {:error, :missing_figma_mcp_client_id} =
               OAuthRefresher.refresh(:figma_oauth, "good-figma")

      Application.put_env(:backplane, OAuthRefresher,
        figma_token_url: "http://localhost:#{port}/figma/token",
        figma_mcp_client_id: "test-figma-client"
      )

      assert {:error, :missing_figma_mcp_client_secret} =
               OAuthRefresher.refresh(:figma_oauth, "good-figma")

      Application.put_env(:backplane, OAuthRefresher, configured)
    end

    test "returns a sanitized status error for a rejected refresh" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:figma_oauth, "rejected-figma")
    end
  end

  defp snapshot_env(names) do
    Map.new(names, fn name -> {name, System.get_env(name)} end)
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
