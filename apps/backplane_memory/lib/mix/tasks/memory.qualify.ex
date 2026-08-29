defmodule Mix.Tasks.Memory.Qualify do
  @shortdoc "Run the reproducible M18 Memory V2 qualification suite"
  use Mix.Task

  alias Backplane.Memory.Qualification.{Profile, Runner}

  @usage "usage: mix memory.qualify --profile performance|ci --report <path>"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [report: :string, profile: :string])

    profile = opts |> Keyword.get(:profile, "performance") |> Profile.parse()

    if positional != [] or invalid != [] or match?({:error, :invalid_profile}, profile),
      do: Mix.raise(@usage)

    if Mix.env() != :test,
      do: Mix.raise("memory.qualify is restricted to MIX_ENV=test")

    Mix.Task.run("app.start")
    {:ok, profile} = profile
    runner_opts = [profile: profile]

    result =
      if real_pool?() do
        Runner.run(runner_opts)
      else
        Runner.sandboxed_run(runner_opts)
      end

    case result do
      {:ok, report} ->
        encoded = Backplane.Memory.Qualification.encode_report(report)
        if path = opts[:report], do: File.write!(path, encoded)
        Mix.shell().info(encoded)
        if not report.passed, do: Mix.raise("M18 qualification thresholds failed")

      {:error, reason} ->
        Mix.raise("M18 qualification failed: #{inspect(reason)}")
    end
  end

  defp real_pool? do
    System.get_env("BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL") in ["1", "true"]
  end
end
