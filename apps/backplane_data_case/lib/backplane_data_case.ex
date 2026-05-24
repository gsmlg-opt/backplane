defmodule BackplaneDataCase do
  @moduledoc """
  Shared Ecto sandbox setup for umbrella test cases.

  Per-app `DataCase` modules call `setup_sandbox/2` with their own repo, so
  test support code can live in a low-level umbrella app that does not
  depend on any specific application's Repo.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Start a sandbox owner for `repo`, scoping isolation based on `tags`.

  Mirrors the previous `Backplane.DataCase.setup_sandbox/1` behaviour:
  async tests get an isolated sandbox, sync tests share the connection.
  """
  @spec setup_sandbox(module(), map()) :: :ok
  def setup_sandbox(repo, tags) when is_atom(repo) do
    pid = Sandbox.start_owner!(repo, shared: not tags[:async])
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
