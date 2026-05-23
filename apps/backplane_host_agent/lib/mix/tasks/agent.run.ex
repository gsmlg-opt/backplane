defmodule Mix.Tasks.Agent.Run do
  @moduledoc """
  Runs the Backplane host agent as an explicit development process.
  """

  use Mix.Task

  @shortdoc "Runs the Backplane host agent"

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Application.put_env(:backplane_host_agent, :start_on_application, true)

    case Application.ensure_all_started(:backplane_host_agent) do
      {:ok, _apps} ->
        Mix.shell().info("Backplane host agent started")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start Backplane host agent: #{inspect(reason)}")
    end
  end
end
