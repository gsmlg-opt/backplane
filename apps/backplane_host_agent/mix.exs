defmodule Backplane.HostAgent.MixProject do
  use Mix.Project

  @version "1.10.77"

  def project do
    [
      app: :backplane_host_agent,
      version: @version,
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

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Backplane.HostAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:http_test, "~> 1.0.0-rc.15", only: :test},
      {:backplane_plugin_protocol, in_umbrella: true},
      {:phoenix_socket_client, "~> 0.9.0"},
      {:http_fetch, "~> 1.0.0-rc.15"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:plug, "~> 1.16"},
      {:gaoxy_http, "~> 0.15"},
      {:telemetry, "~> 1.2"},
      {:backplane_memory_contract, in_umbrella: true},
      {:backplane_memory, in_umbrella: true, only: [:dev, :test], runtime: false},
      {:day_ex, in_umbrella: true},
      {:math_ex, in_umbrella: true},
      {:ex_turso, "~> 3.0"}
    ]
  end
end
