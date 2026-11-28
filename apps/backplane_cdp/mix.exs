defmodule Backplane.CDP.MixProject do
  use Mix.Project

  @version "1.10.112"
  @source_url "https://github.com/gsmlg-opt/backplane"

  def application, do: [mod: {Backplane.CDP.Application, []}, extra_applications: [:crypto]]

  def project do
    [
      app: :backplane_cdp,
      version: @version,
      elixir: "~> 1.18",
      description: "Elixir client and tools for the Chrome DevTools Protocol",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]],
      deps: [
        {:http_fetch, "~> 1.0"},
        {:http_web_socket, "~> 1.0"},
        {:formata, "~> 0.4"},
        {:gaoxy_http, "~> 0.15", only: :test},
        {:plug, "~> 1.16", only: :test},
        {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
      ]
    ] ++ umbrella_paths()
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md)
    ]
  end

  defp umbrella_paths do
    umbrella_root = Path.expand("../..", __DIR__)

    if File.regular?(Path.join(umbrella_root, "mix.exs")) and
         File.dir?(Path.join(umbrella_root, "apps")) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end
end
