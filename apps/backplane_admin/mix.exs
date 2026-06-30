defmodule BackplaneAdmin.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_admin,
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
      extra_applications: [:logger, :runtime_tools, :phoenix_ecto],
      mod: {Backplane.Admin.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane, in_umbrella: true},
      {:backplane_auth, in_umbrella: true},
      {:backplane_system, in_umbrella: true},
      {:backplane_mcp, in_umbrella: true},
      {:backplane_llama, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:backplane_memory, in_umbrella: true},
      {:backplane_monitor, in_umbrella: true},
      {:relayixir, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_duskmoon, "~> 9.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:bun, "~> 2.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["bun.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": [
        "cmd mkdir -p priv/static/assets",
        "bun backplane_admin",
        "tailwind backplane_admin"
      ],
      "assets.deploy": [
        "phx.digest.clean",
        "cmd mkdir -p priv/static/assets",
        "bun backplane_admin --minify",
        "tailwind backplane_admin --minify",
        "phx.digest"
      ],
      test: ["test"]
    ]
  end
end
