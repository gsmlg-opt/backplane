defmodule Mix.Tasks.Agent.Memory.Resync do
  @shortdoc "Requeues failed host-agent memory outbox rows"

  @moduledoc """
  Requeues failed host-agent memory outbox rows to `pending`.
  """

  use Mix.Task

  alias Backplane.HostAgent.Memory.Diagnostics

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")

    case Diagnostics.requeue_failed_outbox(store: memory_store!()) do
      {:ok, %{"requeued" => requeued}} ->
        Mix.shell().info("Requeued #{requeued} failed memory outbox row(s).")

      {:error, reason} ->
        Mix.raise("failed to requeue memory outbox rows: #{inspect(reason)}")
    end
  end

  defp memory_store! do
    Application.get_env(:backplane_host_agent, :memory_store) ||
      Mix.raise("host-agent memory store is not configured")
  end
end
