defmodule Backplane.Auth.ResourceAuthProductionTest do
  use Backplane.Auth.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Backplane.Auth.ResourceAuthPlug
  alias Backplane.Clients
  alias Backplane.Clients.AuthCache

  setup do
    previous = Application.get_env(:backplane, :env)
    Application.put_env(:backplane, :env, :prod)
    :ok = Clients.refresh_cache()

    on_exit(fn ->
      Application.put_env(:backplane, :env, previous)
    end)

    :ok
  end

  test "production indexed cache preserves client scopes on both header paths" do
    {:ok, client, token} =
      Clients.issue_client(%{
        name: "production precedence",
        scopes: ["docs::*"]
      })

    for {header, value} <- [
          {"authorization", "Bearer #{token}"},
          {"x-api-key", token}
        ] do
      authenticated = conn(:post, "/mcp") |> put_req_header(header, value) |> authenticate()
      assert authenticated.assigns.resource_auth.kind == :client_token
      assert authenticated.assigns.client.id == client.id
      assert authenticated.assigns.tool_scopes == ["docs::*"]
    end
  end

  test "production protection includes unissued and inactive clients" do
    assert {:ok, unissued} = Clients.create_client(%{name: "unissued production", scopes: ["*"]})
    assert is_nil(unissued.token_digest)
    assert (conn(:post, "/mcp") |> authenticate()).status == 401

    assert {:ok, inactive, token} =
             Clients.issue_client(%{name: "inactive production", scopes: ["*"], active: false})

    assert not inactive.active

    assert (conn(:post, "/mcp") |> put_req_header("x-api-key", token) |> authenticate()).status ==
             401

    assert (conn(:post, "/mcp") |> authenticate()).status == 401
  end

  test "rotation and revocation replace production request authority" do
    assert {:ok, client, token} =
             Clients.issue_client(%{name: "rotation production", scopes: ["docs::*"]})

    assert {:ok, rotated, replacement} = Clients.rotate_client_token(client)

    assert (conn(:post, "/mcp") |> put_req_header("x-api-key", token) |> authenticate()).status ==
             401

    accepted = conn(:post, "/mcp") |> put_req_header("x-api-key", replacement) |> authenticate()
    assert accepted.assigns.resource_auth.client_id == rotated.id
    assert accepted.assigns.resource_auth.scopes == ["docs::*"]
    assert {:ok, _} = Clients.revoke_client_token(rotated)

    assert (conn(:post, "/mcp")
            |> put_req_header("x-api-key", replacement)
            |> authenticate()).status == 401
  end

  test "unavailable cache never falls through to legacy credentials or open mode" do
    token = "bp2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ok = AuthCache.begin_mutation()

    for format <- [:default, :google] do
      rejected =
        conn(:post, "/mcp") |> put_req_header("x-api-key", token) |> authenticate(format)

      assert rejected.status == 503
      assert get_resp_header(rejected, "retry-after") == ["1"]
      refute rejected.assigns[:resource_auth]
      body = Jason.decode!(rejected.resp_body)

      if format == :google,
        do: assert(body["error"]["status"] == "UNAVAILABLE"),
        else: assert(is_binary(body["error"]))
    end

    missing = conn(:post, "/mcp") |> authenticate()
    assert missing.status == 401
    :ok = AuthCache.abort_mutation()
    :ok = Clients.refresh_cache()
  end

  test "oversized and conflicting headers fail before cache admission" do
    for {header, value} <- [
          {"authorization", "Bearer " <> String.duplicate("a", 16_385)},
          {"x-api-key", String.duplicate("a", 16_385)}
        ] do
      rejected = conn(:post, "/mcp") |> put_req_header(header, value) |> authenticate()
      assert rejected.status == 401
    end

    conflict =
      conn(:post, "/mcp")
      |> put_req_header("authorization", "Bearer shared-token")
      |> put_req_header("x-api-key", "shared-token")
      |> authenticate()

    assert conflict.status == 401
  end

  test "owner restart starts uninitialized rather than open" do
    Ecto.Adapters.SQL.query!(Backplane.Repo, "SET LOCAL search_path TO pg_catalog")
    old_owner = Process.whereis(AuthCache)
    reference = Process.monitor(old_owner)
    Process.exit(old_owner, :kill)
    assert_receive {:DOWN, ^reference, :process, ^old_owner, :killed}, 1_000

    eventually(fn ->
      owner = Process.whereis(AuthCache)
      assert is_pid(owner) and owner != old_owner
      assert AuthCache.any_clients?()

      assert {:error, :unavailable} =
               AuthCache.verify(
                 "bp2_" <> Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
               )
    end)

    Ecto.Adapters.SQL.query!(Backplane.Repo, "SET LOCAL search_path TO public")
    :ok = Clients.refresh_cache()
  end

  defp authenticate(conn, format \\ :default),
    do: ResourceAuthPlug.call(conn, ResourceAuthPlug.init(resource: :mcp, error_format: format))

  defp eventually(assertion, attempts \\ 100) do
    assertion.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end
end
