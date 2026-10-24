if Mix.env() != :dev, do: Mix.raise("development host-agent setup requires MIX_ENV=dev")

Logger.configure(level: :warning)
{:ok, _apps} = Application.ensure_all_started(:backplane_skills)
Code.require_file("devenv_host_agent.ex", __DIR__)

case Backplane.Scripts.DevenvHostAgent.prepare(System.fetch_env!("BACKPLANE_HOST_AGENT_CONFIG")) do
  {:ok, metadata} ->
    IO.puts("Prepared development host agent #{metadata.name}: #{metadata.config_path}")

  {:error, reason} ->
    Mix.raise("development host-agent setup failed: #{reason}")
end
