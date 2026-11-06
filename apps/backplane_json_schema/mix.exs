defmodule Backplane.JsonSchema.MixProject do
  use Mix.Project

  @version "1.10.58"

  def project do
    [
      app: :backplane_json_schema,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
      {:ex_json_pointer, "~> 0.9"},
      {:decimal, "~> 3.0", optional: true},
      {:jason, "~> 1.4"}
    ]
  end
end
