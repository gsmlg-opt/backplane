defmodule Backplane.Api.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Api.Endpoint

      import Phoenix.ConnTest
      import Plug.Conn
      import Backplane.Api.ConnCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
