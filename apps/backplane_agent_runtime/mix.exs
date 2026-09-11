defmodule Backplane.AgentRuntime.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :backplane_agent_runtime,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embedded Elixir/OTP runtime for bounded independent agents.",
      package: package()
    ]
  end

  def application do
    [
      mod: {Backplane.AgentRuntime.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gsmlg-dev/backplane"},
      maintainers: ["gsmlg-dev"]
    ]
  end
end
