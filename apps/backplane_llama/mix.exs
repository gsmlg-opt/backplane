defmodule BackplaneLlama.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_llama,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BackplaneLlama.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:relayixir, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:phoenix, "~> 1.8"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      {:req, "~> 0.5", override: true},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
