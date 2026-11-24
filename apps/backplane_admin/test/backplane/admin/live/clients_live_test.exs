defmodule Backplane.Admin.ClientsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.Fixtures

  alias Backplane.Clients
  alias Backplane.Repo
  alias Backplane.Settings.Setting

  test "global client authentication bypass requires confirmation before persisting", %{
    conn: conn
  } do
    setting = "clients.auth_bypass.enabled"
    previous = :ets.lookup(:backplane_settings, setting)

    on_exit(fn ->
      :ets.delete(:backplane_settings, setting)
      :ets.insert(:backplane_settings, previous)
    end)

    {:ok, view, _html} = live(conn, "/system/clients")
    refute has_element?(view, "#client-auth-bypass-modal")
    refute has_element?(view, "#client-auth-bypass-status")
    render_click(view, "confirm-auth-bypass")
    refute Clients.auth_bypass_enabled?()

    view |> element("#client-actions", "Actions") |> render_click()
    assert has_element?(view, "#client-auth-bypass[role=switch]:not([checked])")

    view
    |> form("#client-auth-bypass-form", bypass: %{enabled: "true"})
    |> render_submit()

    assert has_element?(view, "#confirm-client-auth-bypass", "Enable bypass")
    refute has_element?(view, "#client-auth-bypass-status")
    refute Clients.auth_bypass_enabled?()
    view |> element("#cancel-client-auth-bypass") |> render_click()
    refute has_element?(view, "#client-auth-bypass-modal")
    refute Clients.auth_bypass_enabled?()

    view |> element("#client-actions") |> render_click()
    refute has_element?(view, "#client-auth-bypass[checked]")

    view
    |> form("#client-auth-bypass-form", bypass: %{enabled: "true"})
    |> render_submit()

    view |> element("#confirm-client-auth-bypass") |> render_click()
    refute has_element?(view, "#client-auth-bypass-modal")
    assert Repo.get!(Setting, setting).value == %{"v" => true}
    assert has_element?(view, "#client-auth-bypass-status", "Client auth bypass enabled")

    view |> element("#client-actions") |> render_click()
    assert has_element?(view, "#client-auth-bypass[checked]")

    {:ok, reopened, _html} = live(conn, "/system/clients")
    assert has_element?(reopened, "#client-auth-bypass-status", "Client auth bypass enabled")
    reopened |> element("#client-actions") |> render_click()
    assert has_element?(reopened, "#client-auth-bypass[checked]")

    reopened
    |> form("#client-auth-bypass-form", bypass: %{enabled: "false"})
    |> render_submit()

    assert Clients.auth_bypass_enabled?()
    assert has_element?(reopened, "#confirm-client-auth-bypass", "Disable bypass")
    reopened |> element("#confirm-client-auth-bypass") |> render_click()

    assert Repo.get!(Setting, setting).value == %{"v" => false}
    refute has_element?(reopened, "#client-auth-bypass-modal")
    refute has_element?(reopened, "#client-auth-bypass-status")
    refute has_element?(view, "#client-auth-bypass-status")
    refute has_element?(view, "#client-auth-bypass[checked]")

    assert [_, _] =
             Backplane.Admin.Audit.list(%{target_type: "system_setting", target_id: setting})
  end

  test "lists client details and binds status and delete actions to the client row", %{conn: conn} do
    {:ok, client} = Clients.create_client(%{name: "table-client", scopes: ["skill::*"]})
    {:ok, view, _html} = live(conn, "/system/clients")

    row = "#clients-table tbody tr"
    assert has_element?(view, "#clients-table th", "Token issued at")
    assert has_element?(view, "#{row} td", client.name)
    assert has_element?(view, "#{row} td", "Active")
    assert has_element?(view, "#{row} td", "Not issued")
    assert has_element?(view, "#{row} td", "skill::*")
    assert has_element?(view, "#{row} td", "Never")
    assert has_element?(view, "#toggle-client-#{client.id}[command=show-modal]")

    view
    |> element("#toggle-client-#{client.id}-confirm", "Deactivate")
    |> render_click()

    assert has_element?(view, "#{row} td", "Inactive")
    assert has_element?(view, ~s(#{row} button[aria-label="Activate #{client.name}"]))

    view |> element("#toggle-client-#{client.id}-confirm", "Activate") |> render_click()
    assert Clients.get_client(client.id).active

    view
    |> element("#delete-client-#{client.id}-confirm")
    |> render_click()

    refute has_element?(view, row)
    assert has_element?(view, "#clients-empty", "No clients configured")
  end

  test "creates and shows the token only after commit, then forgets it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/clients")
    html = view |> element("#new-client") |> render_click()
    refute html =~ ~r/bp(?:2)?_[A-Za-z0-9_-]{32,}/
    assert has_element?(view, "dialog#client-form-modal #client-form")

    view
    |> form("#client-form", client: %{name: "", scopes: "skill::*"})
    |> render_submit()

    assert has_element?(view, "dialog#client-form-modal #client-form")
    assert has_element?(view, "#client-scopes[value='skill::*']")
    view |> element("#cancel-client-form") |> render_click()
    refute has_element?(view, "#client-form-modal")

    view |> element("#new-client") |> render_click()
    assert has_element?(view, "#client-scopes[value='*']")

    html =
      view
      |> form("#client-form", client: %{name: "new-issued-client", scopes: "skill::*"})
      |> render_submit()

    assert [token] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert {:ok, client} = Clients.verify_token(token)
    assert client.name == "new-issued-client"
    refute has_element?(view, "#client-form-modal")
    refute is_nil(client.token_issued_at)

    assert has_element?(
             view,
             "#clients-table time[datetime='#{DateTime.to_iso8601(client.token_issued_at)}']"
           )

    refute render_click(view, "dismiss_token") =~ token
    refute render_click(view, "edit", %{"id" => client.id}) =~ token
  end

  test "unissued clients can be issued a replacement in place", %{conn: conn} do
    assert {:ok, client} = Clients.create_client(%{name: "unissued", scopes: ["*"]})
    {:ok, view, html} = live(conn, "/system/clients")
    assert html =~ "Not issued"

    html =
      view
      |> element("#rotate-client-token-#{client.id}-confirm", "Issue Token")
      |> render_click()

    assert [token] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert {:ok, issued} = Clients.verify_token(token)
    assert issued.id == client.id
    assert %DateTime{} = issued.token_issued_at
  end

  test "rotation preserves identity and invalidates the old token", %{conn: conn} do
    {client, token} = insert_client(name: "rotated-client")
    Repo.update!(Ecto.Changeset.change(client, token_issued_at: nil))
    {:ok, view, _html} = live(conn, "/system/clients")
    assert has_element?(view, "#clients-table td", "Unknown")
    assert has_element?(view, "#rotate-client-token-#{client.id}[command=show-modal]")

    html =
      view
      |> element("#rotate-client-token-#{client.id}-confirm", "Rotate Token")
      |> render_click()

    assert [replacement] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert :error = Clients.verify_token(token)
    assert {:ok, rotated} = Clients.verify_token(replacement)
    assert rotated.id == client.id

    assert has_element?(
             view,
             "#clients-table time[datetime='#{DateTime.to_iso8601(rotated.token_issued_at)}']"
           )
  end

  test "editing scopes preserves the existing bearer token", %{conn: conn} do
    {client, token} = insert_client(name: "codex-test-client")

    assert {:ok, verified} = Clients.verify_token(token)
    assert verified.id == client.id

    {:ok, view, _html} = live(conn, "/system/clients")

    view
    |> element("#edit-client-#{client.id}")
    |> render_click()

    assert has_element?(view, "dialog#client-form-modal #client-name[disabled]")
    view |> form("#client-form", client: %{scopes: "skill::*"}) |> render_submit()
    refute has_element?(view, "#client-form-modal")

    reloaded = Repo.get!(Backplane.Clients.Client, client.id)

    assert reloaded.scopes == ["skill::*"]
    assert reloaded.token_issued_at == client.token_issued_at
    assert {:ok, verified_after_edit} = Clients.verify_token(token)
    assert verified_after_edit.id == client.id

    Process.sleep(100)
  end
end
