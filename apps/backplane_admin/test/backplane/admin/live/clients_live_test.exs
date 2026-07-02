defmodule Backplane.Admin.ClientsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Fixtures

  alias Backplane.Clients
  alias Backplane.Repo

  test "editing scopes preserves the existing bearer token", %{conn: conn} do
    {client, token} = insert_client(name: "codex-test-client", token: "bp_existing_token")

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
