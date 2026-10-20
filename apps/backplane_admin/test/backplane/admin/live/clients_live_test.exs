defmodule Backplane.Admin.ClientsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.Fixtures

  alias Backplane.Clients
  alias Backplane.Repo

  test "creates and shows the token only after commit, then forgets it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/clients")
    html = render_click(view, "new")
    refute html =~ ~r/bp(?:2)?_[A-Za-z0-9_-]{32,}/

    html =
      render_submit(view, "save", %{
        "client" => %{"name" => "new-issued-client", "scopes" => "skill::*"}
      })

    assert [token] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert {:ok, client} = Clients.verify_token(token)
    assert client.name == "new-issued-client"
    refute render_click(view, "dismiss_token") =~ token
    refute render_click(view, "edit", %{"id" => client.id}) =~ token
  end

  test "unissued clients can be issued a replacement in place", %{conn: conn} do
    assert {:ok, client} = Clients.create_client(%{name: "unissued", scopes: ["*"]})
    {:ok, view, html} = live(conn, "/system/clients")
    assert html =~ "Not issued"
    render_click(view, "edit", %{"id" => client.id})
    html = render_click(view, "rotate_token")
    assert [token] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert {:ok, issued} = Clients.verify_token(token)
    assert issued.id == client.id
  end

  test "rotation preserves identity and invalidates the old token", %{conn: conn} do
    {client, token} = insert_client(name: "rotated-client")
    {:ok, view, _html} = live(conn, "/system/clients")
    render_click(view, "edit", %{"id" => client.id})
    html = render_click(view, "rotate_token")
    assert [replacement] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, html)
    assert :error = Clients.verify_token(token)
    assert {:ok, rotated} = Clients.verify_token(replacement)
    assert rotated.id == client.id
  end

  test "editing scopes preserves the existing bearer token", %{conn: conn} do
    {client, token} = insert_client(name: "codex-test-client")

    assert {:ok, verified} = Clients.verify_token(token)
    assert verified.id == client.id

    {:ok, view, _html} = live(conn, "/system/clients")

    view
    |> element(~s(el-dm-button[phx-click="edit"][phx-value-id="#{client.id}"]))
    |> render_click()

    render_submit(view, "save", %{
      "client" => %{"name" => client.name, "scopes" => "skill::*"}
    })

    reloaded = Repo.get!(Backplane.Clients.Client, client.id)

    assert reloaded.scopes == ["skill::*"]
    assert {:ok, verified_after_edit} = Clients.verify_token(token)
    assert verified_after_edit.id == client.id

    Process.sleep(100)
  end
end
