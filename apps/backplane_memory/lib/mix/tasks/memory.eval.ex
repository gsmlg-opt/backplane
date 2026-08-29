defmodule Mix.Tasks.Memory.Eval do
  @shortdoc "Run the guarded M15 Recall V2 evaluation"
  use Mix.Task

  alias Backplane.Memory.Eval
  alias Backplane.Memory.Eval.Runner
  alias Backplane.Memory.Qualification.Profile

  @usage "usage: mix memory.eval --profile performance|ci [--report PATH] [--longmemeval PATH] [--sidecar PATH]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [report: :string, longmemeval: :string, sidecar: :string, profile: :string]
      )

    profile = opts |> Keyword.get(:profile, "performance") |> Profile.parse()

    if positional != [] or invalid != [] or match?({:error, :invalid_profile}, profile),
      do: Mix.raise(@usage)

    guard_database!(opts)
    Mix.Task.run("app.start")
    {:ok, profile} = profile

    case Runner.sandboxed_run(profile: profile) do
      {:ok, report, export} ->
        write(opts[:report], Eval.encode_report(report))
        write(opts[:longmemeval], export.jsonl)
        write(opts[:sidecar], Jason.encode!(export.sidecar, pretty: true) <> "\n")
        Mix.shell().info(Eval.encode_report(report))
        Eval.ensure_thresholds!(report, profile: profile)

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
