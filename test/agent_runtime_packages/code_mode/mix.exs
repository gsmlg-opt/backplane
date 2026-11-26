defmodule CodeModePackage.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_mode_package,
      version: "0.1.0",
      deps: [
        {:backplane_agent_runtime, path: System.fetch_env!("AGENT_RUNTIME_PATH")}
      ]
    ]
  end
end
