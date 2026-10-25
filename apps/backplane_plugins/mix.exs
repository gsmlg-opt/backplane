defmodule BackplanePlugins.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_plugins,
      version: "1.10.37",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {BackplanePlugins.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane_system, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:backplane_plugin_protocol, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:jason, "~> 1.4"}
    ]
  end
end
