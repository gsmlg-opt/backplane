defmodule Backplane.MemoryContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_memory_contract,
      version: "0.5.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end
