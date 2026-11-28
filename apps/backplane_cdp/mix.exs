defmodule Backplane.CDP.MixProject do
  use Mix.Project

  @version "1.10.110"

  def application, do: [mod: {Backplane.CDP.Application, []}, extra_applications: [:crypto]]

  def project do
    [
      app: :backplane_cdp,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      deps: [
        {:http_fetch, "~> 1.0"},
        {:http_web_socket, "~> 1.0"},
        {:formata, "~> 0.4"},
        {:gaoxy_http, "~> 0.15", only: :test},
        {:plug, "~> 1.16", only: :test}
      ]
    ]
  end
end
