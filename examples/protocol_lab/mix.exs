defmodule ProtocolLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :protocol_lab,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:backplane_ai_protocol, path: "../../apps/backplane_ai_protocol"},
      {:backplane_ai_protocol_testkit,
       path: "../../apps/backplane_ai_protocol_testkit", only: :dev}
    ]
  end

  defp escript do
    [main_module: ProtocolLab.CLI]
  end
end
