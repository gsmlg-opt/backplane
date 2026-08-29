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
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    :ok
  end
end
