defmodule BackplaneAuth.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_auth,
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
      extra_applications: [:logger],
      mod: {BackplaneAuth.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:ecto_sql, "~> 3.12"},
      {:bcrypt_elixir, "~> 3.0"},
      {:boruta, "~> 2.3"},
      {:joken, "~> 2.6"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      test: ["test"]
    ]
  end
end
