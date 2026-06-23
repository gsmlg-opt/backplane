defmodule Backplane.Api.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Api.Endpoint

      import Phoenix.ChannelTest
      import Backplane.Api.ChannelCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
