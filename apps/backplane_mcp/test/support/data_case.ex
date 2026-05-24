defmodule BackplaneMcp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BackplaneMcp.DataCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
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
