defmodule Backplane.AgentRuntime.MixProject do
  use Mix.Project

  @version "1.10.38"

  def project do
    [
      app: :backplane_agent_runtime,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embedded Elixir/OTP runtime and opt-in tools for bounded independent agents.",
      docs: docs(),
      package: package()
    ] ++ umbrella_paths()
  end

  def application do
    [
      mod: {Backplane.AgentRuntime.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      protocol_dependency(:backplane_plugin_protocol),
      protocol_dependency(:backplane_mcp_protocol),
      {:jsonschex, "~> 0.10.0"},
      {:decimal, "~> 3.0"},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp protocol_dependency(app) do
    if File.dir?(Path.expand("../../apps", __DIR__)) do
      {app, in_umbrella: true}
    else
      {app, protocol_requirement(app)}
    end
  end

  defp protocol_requirement(:backplane_mcp_protocol), do: "~> 1.10.44"
  defp protocol_requirement(:backplane_plugin_protocol), do: "~> 1.10.32"

  defp umbrella_paths do
    if File.dir?(Path.expand("../../apps", __DIR__)) do
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

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CODEX.md",
        {"c_src/README.md", filename: "native-pty", title: "Linux PTY native helper"},
        "EMBEDDING.md",
        "PERSISTENCE.md",
        "SCHEMAS.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "priv/codex",
        "priv/local_command_launcher.sh",
        "c_src",
        "mix.exs",
        "*.md",
        "examples"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
      maintainers: ["gsmlg-dev"]
    ]
  end
end
