defmodule MathEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :math_ex,
      version: "0.3.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:decimal, "~> 3.0"},
      {:complex, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
