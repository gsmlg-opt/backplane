defmodule BackplaneMemory.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_memory,
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
      extra_applications: [:logger, :crypto, :tzdata],
      mod: {BackplaneMemory.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:pgvector, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5", override: true},
      {:oban, "~> 2.18"},
      {:tzdata, "~> 1.1"}
    ]
  end
end
