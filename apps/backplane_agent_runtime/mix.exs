defmodule Backplane.AgentRuntime.MixProject do
  use Mix.Project

  @version "1.7.0"

  def project do
    [
      app: :backplane_agent_runtime,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embedded Elixir/OTP runtime and opt-in tools for bounded independent agents.",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      mod: {Backplane.AgentRuntime.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "EMBEDDING.md", "PERSISTENCE.md", "SCHEMAS.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: ["lib", "priv", "mix.exs", "*.md", "examples"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
      maintainers: ["gsmlg-dev"]
    ]
  end
end
