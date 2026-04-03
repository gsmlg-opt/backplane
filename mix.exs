defmodule Backplane.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app backplane ecto.setup"],
      "ecto.reset": ["do --app backplane ecto.reset"],
      "ecto.migrate": ["do --app backplane ecto.migrate"],
      "assets.deploy": ["do --app backplane_web assets.deploy"],
      test: ["test"]
    ]
  end
end
