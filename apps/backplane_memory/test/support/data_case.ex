defmodule BackplaneMemory.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
