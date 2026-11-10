defmodule Backplane.JsonSchema.MixProject do
  use Mix.Project

  @version "1.10.68"

  def project do
    [
      app: :backplane_json_schema,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "JSON Schema Draft 2020-12 and Draft 7 compiler and validator for Backplane",
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
        files: ~w(lib mix.exs README.md)
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
      {:ex_json_pointer, "~> 0.9"},
      {:decimal, "~> 3.0", optional: true},
      {:jason, "~> 1.4"},
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
