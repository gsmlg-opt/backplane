defmodule Backplane.ChannelCase do
  @moduledoc """
  Base case template for Phoenix channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BackplaneWeb.Endpoint

      import Phoenix.ChannelTest
      import Backplane.ChannelCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
