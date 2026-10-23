defmodule BackplanePlugins.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    :ok
  end
end
