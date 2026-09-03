defmodule Backplane.Admin.LiveCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Admin.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Backplane.Admin.LiveCase, only: [live_with_sandbox: 2, allow_sandbox_access!: 1]
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Starts a LiveView and grants the LiveView process SQL sandbox access.
  """
  defmacro live_with_sandbox(conn, path) do
    quote do
      {:ok, view, _html} = Phoenix.LiveViewTest.live(unquote(conn), unquote(path))
      Backplane.Admin.LiveCase.allow_sandbox_access!(view)
      html = Phoenix.LiveViewTest.render_patch(view, unquote(path))
      {:ok, view, html}
    end
  end

  def allow_sandbox_access!(view) do
    Ecto.Adapters.SQL.Sandbox.allow(Backplane.Repo, self(), view.pid)
  end
end
