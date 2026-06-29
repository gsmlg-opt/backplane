defmodule BackplaneSystem.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_system,
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
      extra_applications: [:logger, :crypto],
      mod: {BackplaneSystem.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bcrypt_elixir, "~> 3.0"},
      {:req, "~> 0.5", override: true},
      {:oban, "~> 2.18"},
      {:boruta, "~> 2.3"},
      {:joken, "~> 2.6"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
