defmodule BackplaneWeb.PageControllerTest do
  use Backplane.LiveCase, async: false

  setup do
    original_username = Application.get_env(:backplane, :admin_username)
    original_password = Application.get_env(:backplane, :admin_password)

    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    on_exit(fn ->
      restore_env(:admin_username, original_username)
      restore_env(:admin_password, original_password)
    end)
  end

  test "GET / renders public project setup documentation without admin auth", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Backplane"
    assert html_response(conn, 200) =~ "LLM API setup"
    assert html_response(conn, 200) =~ "MCP server setup"
    assert html_response(conn, 200) =~ "/admin/providers"
    assert html_response(conn, 200) =~ "/admin/hub/upstreams"
    assert html_response(conn, 200) =~ "el-dm-button"
    assert html_response(conn, 200) =~ "badge"
    assert html_response(conn, 200) =~ "Claude Code setup"
    assert html_response(conn, 200) =~ "Codex setup"
    assert html_response(conn, 200) =~ "ANTHROPIC_BASE_URL"
    assert html_response(conn, 200) =~ "openai_base_url"
    assert html_response(conn, 200) =~ "~/.codex/config.toml"
    assert html_response(conn, 200) =~ "http://10.100.10.17:4220/llm"
    assert html_response(conn, 200) =~ "http://10.100.10.17:4220/mcp"
    assert html_response(conn, 200) =~ "appbar"
    assert html_response(conn, 200) =~ "theme-controller-dropdown"
    assert html_response(conn, 200) =~ ~s(phx-hook="ThemeSwitcher")
    assert html_response(conn, 200) =~ "Documentation"
    assert html_response(conn, 200) =~ "Agent setup"
    assert html_response(conn, 200) =~ "<footer"
    assert html_response(conn, 200) =~ "bg-secondary text-secondary-content"
    assert html_response(conn, 200) =~ "Operations first, public by default"
    assert html_response(conn, 200) =~ ~s(id="home-body")
    assert html_response(conn, 200) =~ "max-w-7xl"
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
