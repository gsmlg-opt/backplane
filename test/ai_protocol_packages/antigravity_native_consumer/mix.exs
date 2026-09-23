defmodule AntigravityNativeConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :antigravity_native_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:backplane_ai_protocol, path: System.fetch_env!("AI_PROTOCOL_PACKAGE_PATH")}]
  end
end
