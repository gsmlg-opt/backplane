defmodule BackplaneMemory.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BackplaneMemory.DataCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
