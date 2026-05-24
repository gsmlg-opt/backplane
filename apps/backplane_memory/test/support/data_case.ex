defmodule BackplaneMemory.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BackplaneMemory.DataCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(repo(), tags)
    :ok
  end

  @doc "Repo configured for backplane_memory (runtime-resolved to avoid compile-time cross-app coupling)."
  def repo, do: Application.fetch_env!(:backplane_memory, :repo)

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
