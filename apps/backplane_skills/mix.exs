defmodule BackplaneSkills.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_skills,
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
      mod: {BackplaneSkills.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.5", override: true},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:file_system, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
