defmodule Backplane.AgentTools.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :backplane_agent_tools,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Optional, opt-in tool families for Backplane Agent Runtime.",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    if Mix.env() == :prod do
      [{:backplane_agent_runtime, "~> 0.1.0"}]
    else
      [{:backplane_agent_runtime, in_umbrella: true}]
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gsmlg-dev/backplane"},
      maintainers: ["gsmlg-dev"]
    ]
  end
end
