defmodule BackplaneMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_mcp,
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
      mod: {BackplaneMcp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_llama, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:day_ex, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.5", override: true},
      {:lazy_html, ">= 0.1.0"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.0"},
      {:complex, "~> 0.5"},
      {:nx, "~> 0.7"},
      {:nimble_parsec, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
