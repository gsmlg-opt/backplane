defmodule Backplane.Admin.AdminAuditTest do
  use Backplane.Admin.LiveCase, async: false
  alias Backplane.Admin.Audit
  alias Backplane.Admin.Audit.Event
  alias Backplane.Repo

  test "audit insertion failures are reported and do not create records" do
    Repo.delete_all(Event)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Ecto.Changeset{}} = Audit.record(nil, "client")
      end)

    assert log =~ "Admin audit persistence failed"
    assert [] = Audit.list()
  end

  test "audit page advances bounded pages without repeating events", %{conn: conn} do
    Repo.delete_all(Event)
    for _ <- 1..51, do: Audit.record("client.create", "client", Ecto.UUID.generate())
    expected = Audit.list(%{action: "client.create"}, limit: 100)
    first_id = hd(expected).target_id
    last_id = List.last(expected).target_id
    {:ok, view, html} = live_with_sandbox(conn, "/system/logs/audit?action=client.create")
    assert html =~ first_id
    refute html =~ last_id
    assert has_element?(view, "#admin-audit-table tbody tr")
    next_html = render_click(view, "next_page")
    assert next_html =~ last_id
    refute next_html =~ first_id
    refute has_element?(view, "el-dm-button", "Next page")
  end

  test "tag operations record acknowledgements without raw tag names", %{conn: conn} do
    Repo.delete_all(Event)
    {:ok, view, _} = live_with_sandbox(conn, "/skills/metadata")
    render_click(view, "edit-tag", %{"tag" => "private-tag"})
    assert [] = Audit.list()
    render_click(view, "rename-tag", %{"new_name" => "private-renamed-tag"})
    render_click(view, "delete-tag", %{"tag" => "private-renamed-tag"})

    assert [
             %{action: "skill_tag.delete_requested", target_id: nil},
             %{action: "skill_tag.rename_requested", target_id: nil}
           ] = Audit.list()

    refute inspect(Audit.list()) =~ "private-tag"
    refute inspect(Audit.list()) =~ "private-renamed-tag"
  end

  test "query filters, stable ordering and bounded pagination" do
    Repo.delete_all(Event)
    for _ <- 1..55, do: Audit.record("client.create", "client", Ecto.UUID.generate())
    {:ok, other} = Audit.record("provider.delete", "provider", Ecto.UUID.generate())

    assert [^other] =
             Audit.list(%{
               action: "provider.delete",
               target_type: "provider",
               target_id: other.target_id
             })

    first = Audit.list(%{action: "client.create"}, limit: 50)
    assert length(first) == 50
    last = List.last(first)

    remaining =
      Audit.list(%{action: "client.create"}, limit: 50, cursor: {last.inserted_at, last.id})

    assert length(remaining) == 5
    refute Enum.any?(remaining, &(&1.id in Enum.map(first, fn row -> row.id end)))
    assert [] = Audit.list(%{since: DateTime.add(DateTime.utc_now(), 3600)})
    assert [] = Audit.list(%{until: DateTime.add(DateTime.utc_now(), -3600)})
  end

  test "successful client mutations record once without secrets; failures and clicks do not", %{
    conn: conn
  } do
    Repo.delete_all(Event)
    {:ok, view, _} = live_with_sandbox(conn, "/system/clients")
    render_click(view, "new")
    render_click(view, "regenerate_token")
    render_click(view, "validate", %{"client" => %{"name" => "", "scopes" => "*"}})
    render_click(view, "save", %{"client" => %{"name" => "", "scopes" => "*"}})
    assert [] = Audit.list()
    name = "audit-client-#{System.unique_integer([:positive])}"
    render_click(view, "save", %{"client" => %{"name" => name, "scopes" => "*"}})
    assert [%{action: "client.create", target_id: id}] = Audit.list()
    render_click(view, "edit", %{"id" => id})
    render_click(view, "regenerate_token")
    render_click(view, "save", %{"client" => %{"name" => name, "scopes" => "llm::invoke"}})
    render_click(view, "toggle_active", %{"id" => id})
    render_click(view, "delete", %{"id" => id})

    assert [
             %{action: "client.delete"},
             %{action: "client.toggle"},
             %{action: "client.update"},
             %{action: "client.create"}
           ] = Audit.list()

    records = Repo.all(Event)
    refute inspect(records) =~ name
    refute inspect(records) =~ "bp_"
    refute inspect(records) =~ "token_hash"
    {:ok, audit_view, html} = live_with_sandbox(conn, "/system/logs/audit?action=client.delete")
    assert html =~ "client.delete"
    refute html =~ "client.create"
    refute has_element?(audit_view, "el-dm-button", "Next page")
  end
end
