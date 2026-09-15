Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, true)
Backplane.LLM.LogWriter.detach()

for child_id <- [Backplane.LLM.LogWriter, {Backplane.Observability.Buffer, :llm_proxy}] do
  case Supervisor.terminate_child(BackplaneLlama.Supervisor, child_id) do
    :ok -> :ok
    {:error, :not_found} -> :ok
  end
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)

case Oban.start_link(Application.fetch_env!(:backplane, Oban)) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
