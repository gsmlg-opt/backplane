defmodule Backplane.Admin.UpstreamsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Proxy.{Pool, Upstreams}

  setup do
    clear_pool()
    on_exit(&clear_pool/0)
    :ok
  end

  test "renders upstreams page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/mcp/upstreams")

    assert html =~ "Upstream MCP Servers"
  end

  test "renders new upstream form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mcp/upstreams/new")

    assert html =~ "New Upstream"
    assert html =~ "mcp_upstream[name]"
    assert has_element?(view, "#upstream-protocol-version[name='mcp_upstream[protocol_version]']")

    assert has_element?(
             view,
             "#upstream-protocol-version option[value='2025-11-25'][selected]",
             "2025-11-25 (legacy default)"
           )

    assert has_element?(
             view,
             "#upstream-protocol-version option[value='2026-07-28']",
             "2026-07-28 (strict modern)"
           )

    assert has_element?(
             view,
             "#upstream-protocol-version option[value='auto']",
             "Auto (modern discovery, classified legacy fallback)"
           )
  end

  test "persists a strict modern preference and restores it when editing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/upstreams/new")

    render_submit(view, "save", %{
      "mcp_upstream" =>
        valid_form_params(%{
          "name" => "strict-modern",
          "prefix" => "strictmodern",
          "protocol_version" => "2026-07-28"
        })
    })

    assert_patch(view, "/mcp/upstreams")
    persisted = Upstreams.get_by_name("strict-modern")
    assert Map.has_key?(persisted, :protocol_version)
    assert persisted.protocol_version == "2026-07-28"

    {:ok, edit_view, _html} = live(conn, "/mcp/upstreams/#{persisted.id}/edit")

    assert has_element?(
             edit_view,
             "#upstream-protocol-version option[value='2026-07-28'][selected]"
           )
  end

  test "persists automatic protocol discovery", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/upstreams/new")

    render_submit(view, "save", %{
      "mcp_upstream" =>
        valid_form_params(%{
          "name" => "automatic-protocol",
          "prefix" => "automaticprotocol",
          "protocol_version" => "auto"
        })
    })

    assert_patch(view, "/mcp/upstreams")
    persisted = Upstreams.get_by_name("automatic-protocol")
    assert Map.has_key?(persisted, :protocol_version)
    assert persisted.protocol_version == "auto"
  end

  test "rejects an unknown protocol preference", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/upstreams/new")

    html =
      render_submit(view, "save", %{
        "mcp_upstream" =>
          valid_form_params(%{
            "name" => "unknown-protocol",
            "prefix" => "unknownprotocol",
            "protocol_version" => "latest"
          })
      })

    assert html =~ "is invalid"
    assert Upstreams.get_by_name("unknown-protocol") == nil
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

    {:ok, view, _html} = live(conn, "/mcp/upstreams")

    view
    |> element("[phx-click='toggle'][phx-value-id='#{upstream.id}']")
    |> render_click()

    refute Upstreams.get!(upstream.id).enabled

    view
    |> element("[phx-click='toggle'][phx-value-id='#{upstream.id}']")
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

    {:ok, view, _html} = live(conn, "/mcp/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), &(&1.name == "connect-upstream"))
           end)
  end

  test "renders configured and negotiated protocol status without credential references", %{
    conn: conn
  } do
    {bandit, port} = start_mock_server(:modern)
    on_exit(fn -> stop_bandit(bandit) end)

    {:ok, upstream} =
      create_upstream(%{
        name: "status-upstream",
        prefix: "statusupstream",
        protocol_version: "2026-07-28",
        credential: "internal-credential-reference",
        url: "http://127.0.0.1:#{port}/mcp"
      })

    {:ok, view, _html} = live(conn, "/mcp/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), fn status ->
               status.name == "status-upstream" and
                 Map.get(status, :protocol_preference) == "2026-07-28" and
                 Map.get(status, :negotiation_status) == :ready
             end)
           end)

    html = render(view)
    assert html =~ "Preference: 2026-07-28"
    assert html =~ "Negotiated: 2026-07-28"
    assert html =~ "Era: Modern"
    assert html =~ "Negotiation: Ready"
    refute html =~ "internal-credential-reference"
  end

  test "does not render an unknown negotiated protocol version", %{conn: conn} do
    {view, runtime_pid} = start_status_runtime(conn, "unknown-version")

    :sys.replace_state(runtime_pid, fn state ->
      %{state | negotiated_version: "2099-01-01"}
    end)

    send(view.pid, {:reloaded, %{}})
    html = render(view)

    refute html =~ "2099-01-01"
    refute html =~ "Negotiated:"
    refute html =~ "Negotiation: Ready"
  end

  test "does not render a non-string negotiated protocol value", %{conn: conn} do
    {view, runtime_pid} = start_status_runtime(conn, "non-string-version")

    :sys.replace_state(runtime_pid, fn state ->
      %{state | negotiated_version: %{"unsafe" => "value"}}
    end)

    send(view.pid, {:reloaded, %{}})
    html = render(view)

    refute html =~ "unsafe"
    refute html =~ "Negotiated:"
    refute html =~ "Negotiation: Ready"
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

    {:ok, view, _html} = live(conn, "/mcp/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), &(&1.name == "delete-upstream"))
           end)

    view
    |> element("[phx-click='delete'][phx-value-id='#{upstream.id}']")
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

  defp valid_form_params(overrides) do
    Map.merge(
      %{
        "name" => "form-upstream",
        "prefix" => "formupstream",
        "transport" => "http",
        "url" => "http://127.0.0.1:4200/mcp",
        "auth_scheme" => "none",
        "credential" => "",
        "timeout_ms" => "30000",
        "refresh_interval_ms" => "300000",
        "headers" => "",
        "args" => ""
      },
      overrides
    )
  end

  defp start_status_runtime(conn, suffix) do
    {bandit, port} = start_mock_server()
    on_exit(fn -> stop_bandit(bandit) end)

    name = "status-#{suffix}"

    {:ok, upstream} =
      create_upstream(%{
        name: name,
        prefix: "status#{System.unique_integer([:positive])}",
        protocol_version: "2025-11-25",
        url: "http://127.0.0.1:#{port}/mcp"
      })

    {:ok, view, _html} = live(conn, "/mcp/upstreams")

    view
    |> element("[phx-click='connect'][phx-value-id='#{upstream.id}']")
    |> render_click()

    assert eventually(fn ->
             Enum.any?(Pool.list_upstreams(), fn status ->
               status.name == name and Map.get(status, :negotiation_status) == :ready
             end)
           end)

    {runtime_pid, _status} =
      Enum.find(Pool.list_upstream_pids(), fn {_pid, status} -> status.name == name end)

    {view, runtime_pid}
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

  defp start_mock_server(mode \\ :legacy) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {Backplane.Test.MockMcpPlug, mode: mode},
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
