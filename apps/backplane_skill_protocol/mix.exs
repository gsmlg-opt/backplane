defmodule BackplaneSkillProtocol.MixProject do
  use Mix.Project

  @version "1.6.0"

  def project do
    [
      app: :backplane_skill_protocol,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: "Independent Skill document and bundle protocol core"
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
      files: ~w(lib priv mix.exs README.md)
    ]
  end
end
