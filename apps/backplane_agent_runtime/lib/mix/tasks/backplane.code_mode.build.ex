defmodule Mix.Tasks.Backplane.CodeMode.Build do
  use Mix.Task

  @shortdoc "Build a self-contained Code Mode QuickBEAM runner"
  @moduledoc """
  Builds the resolved consumer's Code Mode runner, including ERTS, application
  beams, native libraries and JavaScript assets. Run this task in the consumer
  project after resolving its dependencies:

      MIX_ENV=prod mix backplane.code_mode.build --output /path/to/runner

  The default output is `Mix.Project.build_path()/backplane_code_mode_runner`.
  The output must not exist. `--no-compile` packages already compiled artifacts.
  The executable is `bin/backplane-code-mode-runner` inside the output directory.
  Move or archive the entire directory; its paths are relative to that executable.

  The boot script starts only QuickBEAM and its dependencies. Agent Runtime and
  its other dependencies are loaded without starting their applications. No host
  runtime configuration, config provider, Mix executable or source tree is used.
  Artifacts are native to the build machine's operating system and architecture.
  """

  @runtime :backplane_agent_runtime
  @engine :duskmoon_quickbeam
  @runner Backplane.AgentRuntime.Codex.CodeMode.Runner
  @name "backplane_code_mode_runner"

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [output: :string, no_compile: :boolean])

    if rest != [],
      do: Mix.raise("Usage: mix backplane.code_mode.build [--output PATH] [--no-compile]")

    unless :os.type() in [{:unix, :linux}, {:unix, :darwin}],
      do: Mix.raise("The Code Mode runner requires Linux or macOS")

    unless opts[:no_compile], do: Mix.Task.run("compile")
    Mix.Task.run("loadpaths", ["--no-compile"])

    output = Path.expand(opts[:output] || Path.join(Mix.Project.build_path(), @name))
    if File.exists?(output), do: Mix.raise("Runner output already exists: #{output}")

    applications = collect_applications([@runtime, @engine])
    started = collect_applications([@engine]) |> Map.keys() |> MapSet.new()
    validate_inputs!(applications)
    staging = output <> ".tmp-#{System.pid()}-#{System.unique_integer([:positive])}"

    try do
      assemble!(staging, applications, started)
      File.rename!(staging, output)
    after
      File.rm_rf!(staging)
    end

    Mix.shell().info(
      "Built Code Mode runner: #{Path.join(output, "bin/backplane-code-mode-runner")}"
    )
  end

  defp collect_applications(apps), do: collect_applications(apps, %{})
  defp collect_applications([], acc), do: acc

  defp collect_applications([app | rest], acc) when is_map_key(acc, app),
    do: collect_applications(rest, acc)

  defp collect_applications([app | rest], acc) do
    directory =
      case :code.lib_dir(app) do
        {:error, _} -> Mix.raise("Missing compiled runner dependency: #{app}")
        path -> List.to_string(path)
      end

    case :file.consult(String.to_charlist(Path.join([directory, "ebin", "#{app}.app"]))) do
      {:ok, [{:application, ^app, properties}]} ->
        optional = Keyword.get(properties, :optional_applications, [])

        dependencies =
          (Keyword.get(properties, :applications, []) ++
             Keyword.get(properties, :included_applications, []))
          |> Enum.reject(&(&1 in optional and match?({:error, _}, :code.lib_dir(&1))))

        entry = %{directory: directory, properties: properties}
        collect_applications(dependencies ++ rest, Map.put(acc, app, entry))

      result ->
        Mix.raise("Cannot read runner application #{app}: #{inspect(result)}")
    end
  end

  defp validate_inputs!(applications) do
    unless Code.ensure_loaded?(@runner) and function_exported?(@runner, :main, 0),
      do: Mix.raise("Compiled Code Mode Runner.main/0 is missing; compile Agent Runtime first")

    runtime = Map.fetch!(applications, @runtime).directory
    engine = Map.fetch!(applications, @engine).directory

    for path <- [
          Path.join(runtime, "priv/codex/code_mode_quickbeam.js"),
          Path.join(runtime, "priv/codex/code_mode_runner.sh"),
          Path.join(engine, "priv/lib/Elixir.QuickBEAM.Native.so")
        ] do
      unless File.regular?(path), do: Mix.raise("Required runner artifact is missing: #{path}")
    end
  end

  defp assemble!(staging, applications, started) do
    lib = Path.join(staging, "lib")
    releases = Path.join(staging, "releases")
    File.mkdir_p!(releases)
    File.mkdir_p!(Path.join(staging, "bin"))

    entries =
      applications
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {app, %{directory: directory, properties: properties}} ->
        version = Keyword.fetch!(properties, :vsn)
        destination = Path.join(lib, "#{app}-#{version}")

        for subdirectory <- ["ebin", "priv"],
            File.dir?(Path.join(directory, subdirectory)) do
          copy_tree!(Path.join(directory, subdirectory), Path.join(destination, subdirectory))
        end

        {app, version, if(MapSet.member?(started, app), do: :permanent, else: :load)}
      end)

    erts = :erlang.system_info(:version) |> List.to_string()
    root = :code.root_dir() |> List.to_string()
    copy_tree!(Path.join(root, "erts-#{erts}"), Path.join(staging, "erts-#{erts}"))

    version =
      applications |> Map.fetch!(@runtime) |> Map.fetch!(:properties) |> Keyword.fetch!(:vsn)

    release =
      {:release, {String.to_charlist(@name), version}, {:erts, String.to_charlist(erts)}, entries}

    boot = Path.join(releases, @name)
    write_term!(boot <> ".rel", release)
    make_boot!(boot, lib)

    write_term!(Path.join(releases, "runner.config"),
      kernel: [
        logger: [{:handler, :default, :logger_std_h, %{config: %{type: :standard_error}}}]
      ],
      logger: [default_handler: [config: [type: :standard_error]]]
    )

    launcher =
      applications
      |> Map.fetch!(@runtime)
      |> Map.fetch!(:directory)
      |> Path.join("priv/codex/code_mode_runner.sh")
      |> File.read!()
      |> String.replace("@ERTS_VERSION@", erts)

    executable = Path.join(staging, "bin/backplane-code-mode-runner")
    File.write!(executable, launcher)
    File.chmod!(executable, 0o755)

    write_term!(Path.join(releases, "manifest.term"), %{
      format: 1,
      entrypoint: {@runner, :main, 0},
      erts: erts,
      architecture: :erlang.system_info(:system_architecture),
      applications: entries,
      schedulers: %{normal: 1, dirty_cpu: 1, dirty_io: 1, async: 1}
    })
  end

  defp make_boot!(boot, lib) do
    # Match Mix.Release's build-only loading; prod consumers prune OTP apps that
    # are not runtime dependencies from the code path.
    Mix.ensure_application!(:sasl)
    paths = Path.wildcard(Path.join(lib, "*/ebin")) |> Enum.map(&String.to_charlist/1)

    case apply(:systools, :make_script, [
           String.to_charlist(boot),
           [
             :silent,
             :no_warn_sasl,
             path: paths,
             variables: [{~c"RUNNER_LIB", String.to_charlist(lib)}]
           ]
         ]) do
      {:ok, _, []} -> :ok
      {:ok, _, warnings} -> Mix.raise("Runner boot warnings: #{inspect(warnings)}")
      error -> Mix.raise("Cannot build runner boot script: #{inspect(error)}")
    end
  end

  # Mix build directories commonly link priv back to source. Dereference while
  # copying so the relocated artifact has no source-tree symlinks.
  defp copy_tree!(source, destination) do
    if File.dir?(source) do
      File.mkdir_p!(destination)

      for entry <- File.ls!(source),
          do: copy_tree!(Path.join(source, entry), Path.join(destination, entry))
    else
      File.cp!(source, destination)
    end
  end

  defp write_term!(path, term),
    do: File.write!(path, :io_lib.format(~c"~tp.~n", [term]))
end
