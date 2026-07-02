defmodule Backplane.HostAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_host_agent,
      version: "0.1.0",
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
      {:phoenix_socket_client, "~> 0.7.0"},
      {:req, "~> 0.5", override: true},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:telemetry, "~> 1.2"},
      {:ex_turso, "~> 0.2"}
    ]
  end
end
