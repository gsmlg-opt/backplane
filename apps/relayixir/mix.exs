defmodule Relayixir.MixProject do
  use Mix.Project

  @version "1.10.61"
  @source_url "https://github.com/gsmlg-dev/relayixir"

  def project do
    [
      app: :relayixir,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "An Elixir-native HTTP/WebSocket reverse proxy built on Gaoxy, Plug, HTTP Fetch, and HTTP WebSocket."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["gsmlg-dev"]
    ]
  end

  defp deps do
    [
      {:gaoxy_http, "~> 0.15.0"},
      {:plug, "~> 1.15"},
      {:http_fetch, "~> 1.0.0-rc.5"},
      {:http_web_socket, "~> 1.0.0-rc.5"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
