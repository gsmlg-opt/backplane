defmodule BackplaneDiagnostics.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_diagnostics,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:backplane_diagnostics_client, in_umbrella: true},
        {:backplane_system, in_umbrella: true},
        {:backplane_data_case, in_umbrella: true, only: :test},
        {:ecto_sql, "~> 3.10"},
        {:formata, "~> 0.4.0", only: :test},
        {:postgrex, "~> 0.19"}
      ]
    ]
  end

  def application, do: [mod: {Backplane.Diagnostics.Application, []}]
end
