defmodule Mix.Tasks.Memory.Eval do
  @shortdoc "Run the guarded M15 Recall V2 evaluation"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: [report: :string, longmemeval: :string, sidecar: :string])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    guard_database!(opts)
    Mix.Task.run("app.start")

    case Backplane.Memory.Eval.Runner.sandboxed_run() do
      {:ok, report, export} ->
        write(opts[:report], Backplane.Memory.Eval.encode_report(report))
        write(opts[:longmemeval], export.jsonl)
        write(opts[:sidecar], Jason.encode!(export.sidecar, pretty: true) <> "\n")
        Mix.shell().info(Backplane.Memory.Eval.encode_report(report))
        Backplane.Memory.Eval.ensure_thresholds!(report)

      {:error, reason} ->
        Mix.raise("M15 evaluation failed: #{inspect(reason)}")
    end
  end

  defp guard_database!(_opts) do
    if Mix.env() != :test, do: Mix.raise("memory.eval is restricted to MIX_ENV=test")
  end

  defp write(nil, _content), do: :ok
  defp write(path, content), do: File.write!(path, content)
end
