defmodule Backplane.Admin.LiveCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Admin.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Backplane.Admin.LiveCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
