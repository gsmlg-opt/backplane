defmodule BackplaneWeb.UpstreamsLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Proxy.{Pool, Upstreams}

  setup do
    clear_pool()
    on_exit(&clear_pool/0)
    :ok
  end

  test "renders upstreams page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/hub/upstreams")

    assert html =~ "Upstream MCP Servers"
  end

  test "renders new upstream form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/hub/upstreams/new")

    assert html =~ "New Upstream"
    assert html =~ "mcp_upstream[name]"
  end

  test "toggles an upstream enabled state", %{conn: conn} do
    {bandit, port} = start_mock_server()
    on_exit(fn -> stop_bandit(bandit) end)

    {:ok, upstream} =
      create_upstream(%{
        enabled: true,
        name: "toggle-upstream",
        prefix: "toggle",
        url: "http://127.0.0.1:#{port}/mcp"
      })

    {:ok, view, _html} = live(conn, "/admin/hub/upstreams")

    view
    |> element("[phx-click='toggle'][phx-value-id='#{upstream.id}']", "Disable")
    |> render_click()

    refute Upstreams.get!(upstream.id).enabled

    view
    |> element("[phx-click='toggle'][phx-value-id='#{upstream.id}']", "Enable")
    |> render_click()

    assert Upstreams.get!(upstream.id).enabled
  end

  test "connect action starts the upstream runtime", %{conn: conn} do
    {bandit, port} = start_mock_server()
    on_exit(fn -> stop_bandit(bandit) end)

    {:ok, upstream} =
      create_upstream(%{
        name: "connect-upstream",
        prefix: "connect",
        url: "http://127.0.0.1:#{port}/mcp"
      })

    {:ok, view, _html} = live(conn, "/admin/hub/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']", "Connect")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), &(&1.name == "connect-upstream"))
           end)
  end

  test "delete action stops the upstream runtime", %{conn: conn} do
    {bandit, port} = start_mock_server()
    on_exit(fn -> stop_bandit(bandit) end)

    {:ok, upstream} =
      create_upstream(%{
        name: "delete-upstream",
        prefix: "delete",
        url: "http://127.0.0.1:#{port}/mcp"
      })

    {:ok, view, _html} = live(conn, "/admin/hub/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']", "Connect")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), &(&1.name == "delete-upstream"))
           end)

    view
    |> element("[phx-click='delete'][phx-value-id='#{upstream.id}']", "Delete")
    |> render_click()

    assert eventually(fn ->
             Enum.all?(Pool.list_upstreams(), &(&1.name != "delete-upstream"))
           end)
  end

  defp create_upstream(attrs) do
    defaults = %{
      name: "test-upstream",
      prefix: "testup",
      transport: "http",
      url: "http://127.0.0.1:4200/mcp",
      headers: %{},
      enabled: true
    }

    Upstreams.create(Map.merge(defaults, attrs))
  end

  defp clear_pool do
    Pool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(Pool, pid)
    end)
  end

  defp eventually(fun, attempts \\ 10)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp start_mock_server do
    {:ok, bandit} =
      Bandit.start_link(
        plug: Backplane.Test.MockMcpPlug,
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {bandit, port}
  end

  defp stop_bandit(bandit) do
    if Process.alive?(bandit) do
      GenServer.stop(bandit)
    end
  catch
    :exit, _ -> :ok
  end
end
