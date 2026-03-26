defmodule Backplane.LiveCase do
  @moduledoc """
  Base case template for LiveView tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BackplaneWeb.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Backplane.LiveCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
