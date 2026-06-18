defmodule Mix.Tasks.Agent.Memory.Tombstones do
  @shortdoc "Inspects or purges host-agent memory tombstones"

  @moduledoc """
  Purges host-agent memory tombstones when `--purge` is passed.
  """

  use Mix.Task

  alias Backplane.HostAgent.Memory.Diagnostics

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case OptionParser.parse!(args, strict: [purge: :boolean]) do
      {[purge: true], []} ->
        purge_tombstones()

      {_opts, []} ->
        Mix.raise("pass --purge to explicitly delete memory tombstones")

      {_opts, _extra} ->
        Mix.raise("unexpected arguments for agent.memory.tombstones")
    end
  end

  defp purge_tombstones do
    case Diagnostics.purge_tombstones(store: memory_store!()) do
      {:ok, %{"purged" => purged}} ->
        Mix.shell().info("Purged #{purged} memory tombstone(s).")

      {:error, reason} ->
        Mix.raise("failed to purge memory tombstones: #{inspect(reason)}")
    end
  end

  defp memory_store! do
    Application.get_env(:backplane_host_agent, :memory_store) ||
      Mix.raise("host-agent memory store is not configured")
  end
end
