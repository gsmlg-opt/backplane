defmodule Backplane.DataCase do
  @moduledoc """
  Base case template for DB-backed tests.
  Sets up Ecto sandbox for test isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Backplane.DataCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags), do: BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
end
