{:ok, _} = Application.ensure_all_started(:backplane_system)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Application.fetch_env!(:backplane_memory, :repo), :manual)

case Styx.start_link(Application.fetch_env!(:backplane, Styx)) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end
