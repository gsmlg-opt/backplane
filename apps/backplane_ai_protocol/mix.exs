defmodule Backplane.AiProtocol.MixProject do
  use Mix.Project

  @version "1.7.0"
  @source_url "https://github.com/gsmlg-opt/backplane/tree/main/apps/backplane_ai_protocol"

  def project do
    [
      app: :backplane_ai_protocol,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Provider-neutral AI protocol contracts and codec primitives without host runtime dependencies."
  end

  defp package do
    %{
      licenses: ["MIT"],
      contributors: ["Backplane contributors"],
      links: %{"GitHub" => @source_url},
      files: ~w[lib mix.exs README.md SOURCE_NOTES.md]
    }
  end
end
