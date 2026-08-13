defmodule Mix.Tasks.Memory.Qualify do
  @shortdoc "Run the reproducible M18 Memory V2 qualification suite"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [report: :string])

    if positional != [] or invalid != [],
      do: Mix.raise("usage: mix memory.qualify --report <path>")

    if Mix.env() != :test,
      do: Mix.raise("memory.qualify is restricted to MIX_ENV=test")

    Mix.Task.run("app.start")

    case Backplane.Memory.Qualification.Runner.sandboxed_run() do
      {:ok, report} ->
        encoded = Backplane.Memory.Qualification.encode_report(report)
        if path = opts[:report], do: File.write!(path, encoded)
        Mix.shell().info(encoded)
        if not report.passed, do: Mix.raise("M18 qualification thresholds failed")

      {:error, reason} ->
        Mix.raise("M18 qualification failed: #{inspect(reason)}")
    end
  end
end
