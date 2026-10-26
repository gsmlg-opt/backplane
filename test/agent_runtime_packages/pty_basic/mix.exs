defmodule PtyBasic.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :pty_basic,
      version: "0.1.0",
      deps: [{:backplane_agent_runtime, path: System.fetch_env!("AGENT_RUNTIME_PATH")}]
    ]

  def application, do: [extra_applications: [:logger]]
end
