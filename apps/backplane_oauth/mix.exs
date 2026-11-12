defmodule BackplaneOauth.MixProject do
  use Mix.Project

  @version "1.10.76"

  # Forked from Hex `boruta` 2.3.8 (https://github.com/malach-it/boruta_auth, MIT).
  # Modules live under `Backplane.Oauth` (upstream `Boruta.Oauth.*` folded into it);
  # configure with `config :backplane_oauth, Backplane.Oauth`.

  def project do
    [
      app: :backplane_oauth,
      version: @version,
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
      mod: {Backplane.Oauth.Supervisor, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "priv/backplane_oauth", "test/support"]
  defp elixirc_paths(_), do: ["lib", "priv/backplane_oauth"]

  defp deps do
    [
      {:ecto_sql, ">= 3.5.2"},
      {:ex_json_schema, "~> 0.6"},
      {:finch, "~> 0.16"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.0"},
      {:jose, "~> 1.11"},
      {:nebulex, "~> 3.0"},
      {:nebulex_distributed, "~> 3.0"},
      {:phoenix, "~> 1.0"},
      {:plug, "~> 1.0"},
      {:postgrex, ">= 0.0.0"},
      {:puid, "~> 1.0"},
      {:secure_random, "~> 0.5"},
      {:shards, "~> 1.0"}
    ]
  end
end
