defmodule BackplanePluginProtocol.MixProject do
  use Mix.Project

  @version "1.10.55"

  def project do
    [
      app: :backplane_plugin_protocol,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:yaml_elixir, "~> 2.9"},
        {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
      ],
      description: "Agent Plugins 1.0 package loading and Backplane distribution client",
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
        files: ~w(lib priv mix.exs README.md)
      ]
    ] ++ umbrella_paths()
  end

  def application, do: [extra_applications: [:crypto]]

  defp umbrella_paths do
    root = Path.expand("../..", __DIR__)

    if File.regular?(Path.join(root, "mix.exs")) and File.dir?(Path.join(root, "apps")) do
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
