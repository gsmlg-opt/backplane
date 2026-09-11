defmodule BackplaneSkillProtocol.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :backplane_skill_protocol,
      version: @version,
      elixir: "~> 1.18",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: "Independent Skill document and bundle protocol core"
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Backplane.SkillProtocol.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:elixir_make, "~> 0.10", runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
      files: ~w(lib priv c_src Makefile mix.exs README.md)
    ]
  end
end
