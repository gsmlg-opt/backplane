# Supported invocation (no provider key needed):
# MEMORY_LOCAL_RUN_ID=<existing-run> devenv shell -- mix run --no-start scripts/memory_local_resource_cutover.exs
if Mix.env() != :dev, do: raise("local fixture credential cutover requires MIX_ENV=dev")
Logger.configure(level: :warning)
run_id = System.fetch_env!("MEMORY_LOCAL_RUN_ID")
unless Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,49}\z/, run_id), do: raise("invalid run ID")

Code.require_file("memory_local_resource_credential.exs", __DIR__)

# Start only the owning processes and their runtime libraries. Starting the
# umbrella or backplane_system application would also start dependency apps.
for app <- [:crypto, :ecto_sql, :postgrex, :phoenix_pubsub, :jason] do
  {:ok, _} = Application.ensure_all_started(app)
end

repo_config =
  Application.fetch_env!(:backplane_system, Backplane.Repo) |> Keyword.put(:log, false)

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Backplane.Repo, repo_config},
      {Phoenix.PubSub, name: Backplane.PubSub},
      {Backplane.Clients.AuthSupervisor, []},
      {Backplane.Settings.Credentials.Vault, []}
    ],
    strategy: :one_for_one
  )

try do
  :ok = Backplane.Clients.refresh_cache()

  case Backplane.Scripts.MemoryLocalResourceCredential.cutover(run_id) do
    {:ok, result} ->
      IO.puts("Fixture resource credential ready (#{result.action}); private token file updated.")

    {:error, reason} ->
      raise("fixture resource credential cutover refused: #{reason}")
  end
after
  Supervisor.stop(supervisor)
end
