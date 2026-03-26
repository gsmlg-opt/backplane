defmodule Backplane.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane,
      version: "0.1.0",
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
      mod: {Backplane.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web — Phoenix serves both MCP (Plug routes) and admin UI (LiveView)
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},

      # Assets — Bun bundler + Tailwind v4 standalone CLI
      {:bun, "~> 1.4", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # HTTP client
      {:req, "~> 0.5"},

      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},

      # Job processing
      {:oban, "~> 2.18"},

      # Config
      {:toml, "~> 0.7"},
      {:yaml_elixir, "~> 2.9"},

      # File watching (local skill sources)
      {:file_system, "~> 1.0"},

      # Telemetry
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Dev/Test
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "bun.install --if-missing"],
      "assets.build": ["tailwind backplane", "bun backplane"],
      "assets.deploy": [
        "tailwind backplane --minify",
        "bun backplane --sourcemap=none",
        "phx.digest"
      ]
    ]
  end
end
