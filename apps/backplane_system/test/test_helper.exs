ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)

case Styx.start_link(Application.fetch_env!(:backplane, Styx)) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
