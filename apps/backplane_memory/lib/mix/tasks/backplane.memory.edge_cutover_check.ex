defmodule Mix.Tasks.Backplane.Memory.EdgeCutoverCheck do
  use Mix.Task

  @shortdoc "Fail closed unless revisioned host memory is ready for cutover"

  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case Backplane.Memory.Readiness.edge_cutover() do
      {:ok, _report} ->
        Mix.shell().info("Memory edge cutover ready")

      {:error, report} ->
        Mix.raise(
          "Memory edge cutover blocked: #{inspect(report.failures)}; error types: #{inspect(report.error_types)}"
        )
    end
  end

  def run(_), do: Mix.raise("usage: mix backplane.memory.edge_cutover_check")
end
