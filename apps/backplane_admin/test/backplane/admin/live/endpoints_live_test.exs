defmodule Backplane.Admin.EndpointsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.Audit
  alias Backplane.Endpoints

  defp create!(attrs) do
    {:ok, endpoint} = Endpoints.create(Map.merge(%{name: "chatgpt"}, attrs))
    endpoint
  end

  defp audit(id),
    do: Audit.list(%{target_type: "endpoint", target_id: id}) |> Enum.map(& &1.action)

  test "System sidebar links to Endpoints", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/endpoints")
    assert has_element?(view, "h1", "Endpoints")
    assert has_element?(view, "a[href='/system/endpoints']", "Endpoints")
    assert has_element?(view, "#endpoints-empty", "No endpoints configured yet")
  end

  test "Add opens a clean modal without an enabled field", %{conn: conn} do
    {:ok, view, _} = live(conn, "/system/endpoints")
    refute has_element?(view, "#endpoint-modal")
    view |> element("#add-endpoint") |> render_click()
    assert_patch(view, "/system/endpoints/new")
    assert has_element?(view, "dialog#endpoint-modal", "Add endpoint")
    assert has_element?(view, "#endpoint-form input[name='endpoint[name]']:not([readonly])")
    refute has_element?(view, "#endpoint-form [name='endpoint[enabled]']")
  end

  test "create adds an enabled row and records audit", %{conn: conn} do
    {:ok, view, _} = live(conn, "/system/endpoints/new")

    render_submit(view, "save", %{
      "endpoint" => %{
        "name" => "chatgpt",
        "description" => "ChatGPT",
        "mcp_enabled" => "true",
        "llm_enabled" => "false",
        "restrict_clients" => "false",
        "mcp_prefixes" => ["", "day"],
        "models" => [""]
      }
    })

    assert_patch(view, "/system/endpoints")
    refute has_element?(view, "#endpoint-modal")
    endpoint = Endpoints.get_by_name("chatgpt")
    assert endpoint.enabled
    assert endpoint.mcp_prefixes == ["day"]
    assert has_element?(view, "#endpoints-table", "chatgpt")
    assert has_element?(view, "#endpoints-table", "Enabled")
    assert has_element?(view, "#endpoints-table", "All clients")
    assert audit(endpoint.id) == ["endpoint.create"]
  end

  test "extra enabled value cannot bypass the default", %{conn: conn} do
    {:ok, view, _} = live(conn, "/system/endpoints/new")
    render_submit(view, "save", %{"endpoint" => %{"name" => "x", "enabled" => "false"}})
    assert Endpoints.get_by_name("x").enabled
  end

  test "edit keeps enabled state and read-only name", %{conn: conn} do
    endpoint = create!(%{enabled: false, mcp_enabled: true})
    {:ok, view, _} = live(conn, "/system/endpoints")
    view |> element("#edit-endpoint-chatgpt") |> render_click()
    assert_patch(view, "/system/endpoints/#{endpoint.id}/edit")
    assert has_element?(view, "dialog#endpoint-modal", "Edit chatgpt endpoint")
    assert has_element?(view, "#endpoint-form input[name='endpoint[name]'][readonly]")

    render_submit(view, "save", %{
      "endpoint" => %{"name" => "renamed", "description" => "new", "mcp_enabled" => "true"}
    })

    updated = Endpoints.get!(endpoint.id)
    assert updated.name == "chatgpt"
    assert updated.description == "new"
    refute updated.enabled
    assert audit(endpoint.id) == ["endpoint.update"]
  end

  test "Cancel writes nothing and next Add is clean", %{conn: conn} do
    create!(%{description: "leftover"})
    {:ok, view, _} = live(conn, "/system/endpoints")
    view |> element("#edit-endpoint-chatgpt") |> render_click()
    assert has_element?(view, "#endpoint-form input[value='leftover']")
    render_click(view, "cancel")
    assert_patch(view, "/system/endpoints")
    refute has_element?(view, "#endpoint-modal")
    assert Endpoints.get_by_name("chatgpt").description == "leftover"

    view |> element("#add-endpoint") |> render_click()
    refute has_element?(view, "#endpoint-form input[value='leftover']")
    refute has_element?(view, "#endpoint-form input[value='chatgpt']")
  end

  test "validation errors keep modal and input", %{conn: conn} do
    {:ok, view, _} = live(conn, "/system/endpoints/new")

    html =
      render_submit(view, "save", %{
        "endpoint" => %{
          "name" => "Bad Name",
          "description" => "keep me",
          "mcp_prefixes" => ["hub"]
        }
      })

    assert has_element?(view, "dialog#endpoint-modal")
    assert has_element?(view, "#endpoint-errors", "name:")
    assert has_element?(view, "#endpoint-errors", "mcp_prefixes:")
    assert html =~ "Bad Name"
    assert html =~ "keep me"
    assert Endpoints.list() == []
  end

  test "toggle switches Status, label and audit", %{conn: conn} do
    endpoint = create!(%{})
    {:ok, view, _} = live(conn, "/system/endpoints")
    assert has_element?(view, "#toggle-endpoint-chatgpt[aria-label='Disable chatgpt endpoint']")
    view |> element("#toggle-endpoint-chatgpt") |> render_click()
    refute Endpoints.get!(endpoint.id).enabled
    assert has_element?(view, "#endpoints-table", "Disabled")
    assert has_element?(view, "#toggle-endpoint-chatgpt[aria-label='Enable chatgpt endpoint']")
    view |> element("#toggle-endpoint-chatgpt") |> render_click()
    assert Endpoints.get!(endpoint.id).enabled
    assert Enum.sort(audit(endpoint.id)) == ["endpoint.disable", "endpoint.enable"]
  end

  test "delete asks for confirmation naming the endpoint and revokes via EndpointAccess", %{
    conn: conn
  } do
    endpoint = create!(%{})
    {:ok, view, _} = live(conn, "/system/endpoints")

    confirm =
      view
      |> element("#delete-endpoint-chatgpt")
      |> render()
      |> Phoenix.HTML.html_escape()
      |> elem(1)

    assert IO.iodata_to_binary(confirm) =~
             "chatgpt endpoint? Every access token issued for it is revoked."

    assert has_element?(view, "#delete-endpoint-chatgpt[data-confirm*='chatgpt']")
    assert has_element?(view, "#delete-endpoint-chatgpt[aria-label='Delete chatgpt endpoint']")

    view |> element("#delete-endpoint-chatgpt") |> render_click()
    assert Endpoints.get_by_name("chatgpt") == nil
    refute has_element?(view, "#endpoints-table")
    assert "endpoint.delete" in audit(endpoint.id)
  end

  test "URLs are shown only for enabled features", %{conn: conn} do
    create!(%{mcp_enabled: true})
    {:ok, view, _} = live(conn, "/system/endpoints")
    assert has_element?(view, "#endpoint-urls-chatgpt-mcp code", "/endpoints/chatgpt/mcp")
    assert has_element?(view, "#endpoint-urls-chatgpt-mcp code", "oauth-protected-resource")
    refute has_element?(view, "#endpoint-urls-chatgpt-llm")
  end

  test "allowlisted entries missing from options show Unavailable and stay selected", %{
    conn: conn
  } do
    endpoint = create!(%{llm_enabled: true, models: ["gone/model"], mcp_prefixes: ["gone"]})
    {:ok, view, _} = live(conn, "/system/endpoints/#{endpoint.id}/edit")
    assert has_element?(view, "#endpoint-models", "Unavailable")
    assert has_element?(view, "#endpoint-mcp_prefixes", "Unavailable")
    assert has_element?(view, "#endpoint-models input[value='gone/model'][checked]")

    render_submit(view, "save", %{
      "endpoint" => %{"models" => ["", "gone/model"], "mcp_prefixes" => ["", "gone"]}
    })

    assert Endpoints.get!(endpoint.id).models == ["gone/model"]
  end

  test "icon buttons have accessible names", %{conn: conn} do
    create!(%{})
    {:ok, view, _} = live(conn, "/system/endpoints")
    assert has_element?(view, "#edit-endpoint-chatgpt[aria-label='Edit chatgpt endpoint']")
    assert has_element?(view, "#toggle-endpoint-chatgpt[aria-label]")
    assert has_element?(view, "#delete-endpoint-chatgpt[aria-label]")
  end
end
