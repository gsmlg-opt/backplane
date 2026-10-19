defmodule Backplane.Admin.SidebarSessionTest do
  use Backplane.Admin.LiveCase, async: false

  import Plug.Conn, only: [get_session: 2]

  alias Backplane.Admin.SidebarSession
  alias Phoenix.SessionProcess

  setup %{conn: conn} do
    conn = get(conn, "/")
    session_id = get_session(conn, :session_id)
    on_exit(fn -> SessionProcess.terminate(session_id) end)
    %{conn: conn, session_id: session_id}
  end

  test "browser sessions receive separate package-generated identities", %{
    conn: conn,
    session_id: session_id
  } do
    other_conn = get(build_conn(), "/")
    other_id = get_session(other_conn, :session_id)
    on_exit(fn -> SessionProcess.terminate(other_id) end)

    assert {:ok, <<_::192>>} = Base.url_decode64(session_id, padding: false)
    assert other_id != session_id
    assert get_session(get(recycle(conn), "/"), :session_id) == session_id
    assert {:ok, true} = SidebarSession.put(session_id, true)
    assert {:ok, false} = SidebarSession.read(other_id)
  end

  test "writes acknowledge persisted state and repeated reads reuse the session", %{
    session_id: session_id
  } do
    assert {:ok, false} = SidebarSession.read(session_id)
    assert {:ok, pid} = SessionProcess.find_session(session_id)
    assert {:ok, true} = SidebarSession.put(session_id, true)
    assert SessionProcess.get_state(session_id) == %{sidebar_collapsed: true}
    assert {:ok, true} = SidebarSession.read(session_id)
    assert {:ok, ^pid} = SessionProcess.find_session(session_id)
    assert {:ok, false} = SidebarSession.put(session_id, false)
  end

  test "terminated sessions are recreated on the next read or write", %{session_id: session_id} do
    assert {:ok, true} = SidebarSession.put(session_id, true)
    assert :ok = SessionProcess.terminate(session_id)
    assert {:ok, false} = SidebarSession.read(session_id)
    assert :ok = SessionProcess.terminate(session_id)
    assert {:ok, true} = SidebarSession.put(session_id, true)
    assert {:ok, true} = SidebarSession.read(session_id)
  end

  test "invalid identities return the package validation failure" do
    assert {:error, {:invalid_session_id, "invalid@id"}} = SidebarSession.read("invalid@id")
  end

  test "root events persist across pages and fresh HTTP requests with the same cookie", %{
    conn: conn,
    session_id: session_id
  } do
    {:ok, view, _html} = live(recycle(conn), "/system/appearance")
    assert has_element?(view, ~s(#admin-sidebar-session[data-sidebar-collapsed="false"]))

    render_hook(view, "sidebar_collapsed", %{"collapsed" => true})
    assert {:ok, true} = SidebarSession.read(session_id)
    assert has_element?(view, ~s(#admin-sidebar-session[data-sidebar-collapsed="true"]))

    {:ok, next_view, _html} =
      view
      |> element(~s(#admin-sidebar a[href="/system/config"]))
      |> render_click()
      |> follow_redirect(conn, "/system/config")

    assert has_element?(next_view, ~s(#admin-sidebar-session[data-sidebar-collapsed="true"]))

    reloaded_conn = get(recycle(conn), "/system/appearance")

    assert reloaded_conn
           |> html_response(200)
           |> Floki.parse_document!()
           |> Floki.find(~s(#admin-sidebar-session[data-sidebar-collapsed="true"]))
           |> length() == 1

    {:ok, reloaded_view, _html} = live(reloaded_conn)
    render_hook(reloaded_view, "sidebar_state", %{})
    assert_reply(reloaded_view, %{collapsed: true})
  end

  test "malformed collapse events preserve state and reconnect reads recover expired sessions", %{
    conn: conn,
    session_id: session_id
  } do
    {:ok, view, _html} = live(recycle(conn), "/system/appearance")
    render_hook(view, "sidebar_collapsed", %{"collapsed" => true})

    for payload <- [%{"collapsed" => "false"}, %{"collapsed" => nil}, %{}] do
      render_hook(view, "sidebar_collapsed", payload)
      assert {:ok, true} = SidebarSession.read(session_id)
    end

    assert Process.alive?(view.pid)
    assert :ok = SessionProcess.terminate(session_id)
    render_hook(view, "sidebar_state", %{})
    assert_reply(view, %{collapsed: false})
    assert has_element?(view, ~s(#admin-sidebar-session[data-sidebar-collapsed="false"]))
  end
end
