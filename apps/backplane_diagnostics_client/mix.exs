defmodule Backplane.DiagnosticsClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_diagnostics_client,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      description: "Backplane Diagnostics event reporting and protocol client",
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/gsmlg-opt/backplane"}
      ],
      deps: [{:formata, "~> 0.4.0"}, {:telemetry, "~> 1.2"}]
    ]
  end

  def application, do: [extra_applications: [:crypto, :inets, :ssl]]
end
