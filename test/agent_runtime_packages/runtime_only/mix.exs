defmodule RuntimeOnly.MixProject do
  use Mix.Project

  def project do
    [
      app: :runtime_only,
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
       path: System.get_env("AGENT_RUNTIME_PATH", "../backplane_agent_runtime")}
    ]
  end
end
