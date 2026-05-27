defmodule Backplane.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Backplane.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_llama, in_umbrella: true},
      {:backplane_mcp, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:backplane_memory, in_umbrella: true},
      {:backplane_telemetry, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},

      # Job processing
      {:oban, "~> 2.18"},

      # Timezone data (must start before Oban)
      {:tzdata, "~> 1.1"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
