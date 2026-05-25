defmodule BackplaneWeb.MemoryLiveTest do
  use Backplane.LiveCase

  alias BackplaneMemory.Memory

  describe "GET /admin/memory/browse" do
    test "renders empty state when no memories exist", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/browse")
      assert html =~ "Memories"
      assert has_element?(view, "h1", "Memories")
      assert render(view) =~ "No memories match"
    end

    test "lists existing memories with type and scope badges", %{conn: conn} do
      {:ok, _} =
        Memory.remember("Paris is in France.",
          agent_id: "a",
          host_id: "h",
          type: "semantic",
          scope: "global"
        )

      {:ok, _view, html} = live(conn, "/admin/memory/browse")
      assert html =~ "Paris is in France."
      assert html =~ "semantic"
      assert html =~ "scope: global"
    end

    test "filters by type via URL params", %{conn: conn} do
      {:ok, _} = Memory.remember("alpha", agent_id: "a", host_id: "h", type: "working")
      {:ok, _} = Memory.remember("beta", agent_id: "a", host_id: "h", type: "semantic")

      {:ok, _view, html} = live(conn, "/admin/memory/browse?type=working")
      assert html =~ "alpha"
      refute html =~ "beta"
    end

    test "soft-deletes a memory via the Forget button", %{conn: conn} do
      {:ok, mem} = Memory.remember("forget me", agent_id: "a", host_id: "h")
      {:ok, view, _html} = live(conn, "/admin/memory/browse")

      assert render(view) =~ "forget me"

      view
      |> element(~s|[phx-click="delete"][phx-value-id="#{mem.id}"]|)
      |> render_click()

      refute render(view) =~ "forget me"
      assert {:error, :not_found} = Memory.get(mem.id)
    end
  end

  describe "GET /admin/memory/stats" do
    test "renders type and scope counts", %{conn: conn} do
      Memory.remember("s1", agent_id: "a", host_id: "h", type: "semantic", scope: "alpha")
      Memory.remember("w1", agent_id: "a", host_id: "h", type: "working", scope: "alpha")

      {:ok, _view, html} = live(conn, "/admin/memory/stats")
      assert html =~ "Memory Stats"
      assert html =~ "Semantic"
      assert html =~ "Working"
      assert html =~ "alpha"
    end
  end

  describe "GET /admin/memory/audit" do
    test "renders audit log page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/audit")
      assert html =~ "Audit Log"
      assert has_element?(view, "h1", "Audit Log")
    end
  end

  describe "GET /admin/memory/sessions" do
    test "renders observation sessions page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/sessions")
      assert html =~ "Sessions"
      assert has_element?(view, "h1", "Sessions")
    end
  end
end
