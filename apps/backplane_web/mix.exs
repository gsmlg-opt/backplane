defmodule BackplaneWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {BackplaneWeb.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane, in_umbrella: true},
      {:relayixir, in_umbrella: true},

      # Web
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_duskmoon, "~> 9.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},

      # Assets
      {:bun, "~> 1.6", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},

      # Dev
      {:phoenix_live_reload, "~> 1.5", only: :dev},

      # Test
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["cmd bun install"],
      "assets.build": [
        "cmd mkdir -p priv/static/assets",
        "cmd env NODE_PATH=../../deps bun build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*",
        "cmd bunx --bun @tailwindcss/cli@4.1.18 --input=assets/css/app.css --output=priv/static/assets/app.css"
      ],
      "assets.deploy": [
        "phx.digest.clean",
        "cmd mkdir -p priv/static/assets",
        "cmd env NODE_PATH=../../deps bun build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/* --minify",
        "cmd bunx --bun @tailwindcss/cli@4.1.18 --input=assets/css/app.css --output=priv/static/assets/app.css --minify",
        "phx.digest"
      ],
      test: ["test"]
    ]
  end
end
