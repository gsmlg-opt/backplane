ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)

case Oban.start_link(Application.fetch_env!(:backplane, Oban)) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
