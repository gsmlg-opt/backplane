defmodule Backplane.Schema.MixProject do
  use Mix.Project

  @version "1.10.77"

  def project do
    [
      app: :backplane_schema,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Declarative raw data structure schema validator and coercer for Backplane",
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
        files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
      ]
    ] ++ umbrella_paths()
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
      {:jason, "~> 1.4", optional: true},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp umbrella_paths do
    root = Path.expand("../..", __DIR__)

    if File.regular?(Path.join(root, "mix.exs")) and File.dir?(Path.join(root, "apps")) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end
end
