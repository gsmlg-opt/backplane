defmodule BackplanePluginProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_plugin_protocol,
      version: "1.10.32",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [{:yaml_elixir, "~> 2.9"}],
      description: "Agent Plugins 1.0 package loading and Backplane distribution client",
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
