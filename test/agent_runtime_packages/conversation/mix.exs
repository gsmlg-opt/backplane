defmodule ConversationConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :conversation_consumer, version: "0.1.0", deps: deps()]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:backplane_agent_runtime, path: System.fetch_env!("AGENT_RUNTIME_PATH")}]
  end
end
