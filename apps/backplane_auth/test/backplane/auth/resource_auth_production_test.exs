defmodule Backplane.Auth.ResourceAuthProductionTest do
  use Backplane.Auth.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Backplane.Auth.ResourceAuthPlug
  alias Backplane.Clients
  alias Backplane.Clients.AuthCache

  setup do
    previous = Application.get_env(:backplane, :env)
    legacy = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane, :env, :prod)
    Application.put_env(:backplane, :auth_token, "shared-token")
    :ok = Clients.refresh_cache()

    on_exit(fn ->
      Application.put_env(:backplane, :env, previous)

      if legacy,
        do: Application.put_env(:backplane, :auth_token, legacy),
        else: Application.delete_env(:backplane, :auth_token)
    end)

    :ok
  end

  test "production cache scopes beat unrestricted configured credentials on both header paths" do
    {:ok, client} =
      Clients.create_client(%{
        name: "production precedence",
        token: "shared-token",
        scopes: ["docs::*"]
      })

    for {header, value} <- [
          {"authorization", "Bearer shared-token"},
          {"x-api-key", "shared-token"}
        ] do
      authenticated = conn(:post, "/mcp") |> put_req_header(header, value) |> authenticate()
      assert authenticated.assigns.resource_auth.kind == :client_token
      assert authenticated.assigns.client.id == client.id
      assert authenticated.assigns.tool_scopes == ["docs::*"]
    end
  end

  test "unavailable cache never falls through to legacy credentials or open mode" do
    :ok = AuthCache.begin_mutation()

    for format <- [:default, :google] do
      rejected =
        conn(:post, "/mcp") |> put_req_header("x-api-key", "shared-token") |> authenticate(format)

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
    assert AuthCache.stats().workers == 0
  end

  test "owner restart kills old workers and starts uninitialized rather than open" do
    Ecto.Adapters.SQL.query!(Backplane.Repo, "SET LOCAL search_path TO pg_catalog")
    old_owner = Process.whereis(AuthCache)
    old_tasks = Process.whereis(Backplane.Clients.Tasks)
    reference = Process.monitor(old_tasks)
    Process.exit(old_owner, :kill)
    assert_receive {:DOWN, ^reference, :process, ^old_tasks, :shutdown}, 1_000

    eventually(fn ->
      owner = Process.whereis(AuthCache)
      assert is_pid(owner) and owner != old_owner
      assert AuthCache.any_clients?()
      assert {:error, :unavailable} = AuthCache.verify("shared-token")
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
