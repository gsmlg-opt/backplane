defmodule RuntimePlusTools.MixProject do
  use Mix.Project

  def project do
    [
      app: :runtime_plus_tools,
      version: "0.1.0",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:backplane_agent_runtime,
       path: System.get_env("AGENT_RUNTIME_PATH", "../backplane_agent_runtime"),
       override: true},
      {:backplane_agent_tools,
       path: System.get_env("AGENT_TOOLS_PATH", "../../apps/backplane_agent_tools")}
    ]
  end
end
