defmodule Backplane.Admin.OAuthCallbackControllerTest do
  use Backplane.Admin.LiveCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.Repo
  alias Backplane.Settings.{Credential, Credentials, OAuthRefresher, OAuthStateStore}

  @redirect_uri "http://localhost:4003/oauth/callback"

  setup do
    OAuthStateStore.clear()

    {:ok, pid} = Bandit.start_link(plug: __MODULE__.FigmaTokenEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(
      :backplane,
      OAuthRefresher,
      Keyword.merge(previous,
        figma_token_url: "http://localhost:#{port}/figma/token",
        figma_mcp_client_id: "figma client",
        figma_mcp_client_secret: "secret:with/slash"
      )
    )

    on_exit(fn ->
      OAuthStateStore.clear()
      Application.put_env(:backplane, OAuthRefresher, previous)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  test "exchanges a Figma code with Basic auth and stores an upstream credential", %{conn: conn} do
    state = put_figma_state("shared-figma")

    conn = get(conn, "/oauth/callback", %{"code" => "valid-code", "state" => state})

    assert redirected_to(conn) == "/system/credentials"

    credential = Repo.get_by!(Credential, name: "shared-figma")
    assert credential.kind == "upstream"
    assert credential.metadata == %{"auth_type" => "figma_oauth"}
    assert {:ok, "figma-access-token"} = Credentials.fetch("shared-figma")
  end

  test "rejects incomplete successful responses without replacing the usable token", %{
    conn: _conn
  } do
    assert {:ok, _} = store_existing("shared-figma")

    for code <- ["missing-refresh", "zero-expiry", "blank-access"] do
      state = put_figma_state("shared-figma")
      response = get(build_conn(), "/oauth/callback", %{"code" => code, "state" => state})

      assert redirected_to(response) == "/system/credentials"
      assert {:ok, "existing-access-token"} = Credentials.fetch("shared-figma")
    end
  end

  test "consumes callback state exactly once", %{conn: conn} do
    state = put_figma_state("shared-figma")

    first = get(conn, "/oauth/callback", %{"code" => "valid-code", "state" => state})
    assert redirected_to(first) == "/system/credentials"

    replay = get(build_conn(), "/oauth/callback", %{"code" => "valid-code", "state" => state})
    assert redirected_to(replay) == "/system/credentials"
    assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ "state expired or invalid"
  end

  test "rejects an unknown state without calling the token endpoint", %{conn: conn} do
    response =
      get(conn, "/oauth/callback", %{
        "code" => "valid-code",
        "state" => "not-a-stored-state"
      })

    assert redirected_to(response) == "/system/credentials"
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "state expired or invalid"
    refute Repo.get_by(Credential, name: "shared-figma")
  end

  test "reports provider denial without creating a credential", %{conn: conn} do
    response =
      get(conn, "/oauth/callback", %{
        "error" => "access_denied",
        "error_description" => "The owner cancelled authorization"
      })

    assert redirected_to(response) == "/system/credentials"
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "owner cancelled"
    refute Repo.get_by(Credential, name: "shared-figma")
  end

  test "does not expose unrelated provider response fields or the client secret", %{conn: conn} do
    state = put_figma_state("shared-figma")

    log =
      capture_log(fn ->
        response =
          get(conn, "/oauth/callback", %{"code" => "rejected-code", "state" => state})

        assert redirected_to(response) == "/system/credentials"
        flash = Phoenix.Flash.get(response.assigns.flash, :error)
        assert flash =~ "expired authorization code"
        refute flash =~ "provider-access-token"
        refute flash =~ "provider-client-secret"
      end)

    refute log =~ "provider-access-token"
    refute log =~ "provider-client-secret"
    refute log =~ "secret:with/slash"
  end

  defp put_figma_state(name) do
    OAuthStateStore.put(%{
      "vendor" => "figma_oauth",
      "cred_name" => name,
      "code_verifier" => "test-code-verifier",
      "redirect_uri" => @redirect_uri
    })
  end

  defp store_existing(name) do
    Credentials.store_oauth_token(
      name,
      "figma_oauth",
      %{
        access_token: "existing-access-token",
        refresh_token: "existing-refresh-token",
        expires_at: System.system_time(:millisecond) + 3_600_000
      },
      "upstream",
      %{}
    )
  end
end

defmodule Backplane.Admin.OAuthCallbackControllerTest.FigmaTokenEndpoint do
  use Plug.Router

  @redirect_uri "http://localhost:4003/oauth/callback"

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  post "/figma/token" do
    expected_auth =
      "Basic " <> Base.encode64("figma+client:secret%3Awith%2Fslash")

    valid_request? =
      get_req_header(conn, "authorization") == [expected_auth] and
        conn.body_params["grant_type"] == "authorization_code" and
        conn.body_params["redirect_uri"] == @redirect_uri and
        conn.body_params["code_verifier"] == "test-code-verifier" and
        conn.body_params["resource"] == "https://mcp.figma.com/mcp"

    cond do
      not valid_request? ->
        json(conn, 400, %{"error" => "invalid_request"})

      conn.body_params["code"] == "valid-code" ->
        json(conn, 200, %{
          "access_token" => "figma-access-token",
          "refresh_token" => "figma-refresh-token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })

      conn.body_params["code"] == "missing-refresh" ->
        json(conn, 200, %{"access_token" => "replacement-access", "expires_in" => 3600})

      conn.body_params["code"] == "zero-expiry" ->
        json(conn, 200, %{
          "access_token" => "replacement-access",
          "refresh_token" => "replacement-refresh",
          "expires_in" => 0
        })

      conn.body_params["code"] == "blank-access" ->
        json(conn, 200, %{
          "access_token" => " ",
          "refresh_token" => "replacement-refresh",
          "expires_in" => 3600
        })

      conn.body_params["code"] == "rejected-code" ->
        json(conn, 401, %{
          "error" => "invalid_grant",
          "error_description" => "expired authorization code",
          "access_token" => "provider-access-token",
          "client_secret" => "provider-client-secret"
        })

      true ->
        json(conn, 400, %{"error" => "unknown_code"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
