defmodule Mix.Tasks.Memory.SeedBench do
  @shortdoc "Validate the schema-v2 coding benchmark seed in a rollback sandbox"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {_opts, _, invalid} = OptionParser.parse(args, strict: [])
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    if Mix.env() != :test, do: Mix.raise("memory.seed_bench is restricted to MIX_ENV=test")

    Mix.Task.run("app.start")
    {:ok, fixture} = Backplane.Memory.Eval.load_fixture()

    case Backplane.Memory.Eval.Runner.sandboxed_seed(fixture) do
      {:ok, ids} ->
        Mix.shell().info(
          "Validated #{map_size(ids)} schema-v2 benchmark memories; transaction rolled back"
        )

      {:error, reason} ->
        Mix.raise("benchmark seed failed: #{inspect(reason)}")
    end
  end
end
