defmodule Backplane.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      release: &release/1,
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app backplane cmd mix ecto.setup"],
      "ecto.reset": ["do --app backplane cmd mix ecto.reset"],
      "ecto.migrate": ["do --app backplane cmd mix ecto.migrate"],
      "agent.run": [
        "do --app backplane_host_agent cmd mix compile",
        "do --app backplane_host_agent cmd mix agent.run"
      ],
      "assets.deploy": ["do --app backplane_web assets.deploy"],
      test: ["test"]
    ]
  end

  defp releases do
    [
      backplane: [
        include_executables_for: [:unix],
        applications: [
          backplane: :permanent,
          backplane_web: :permanent,
          backplane_memory: :permanent,
          runtime_tools: :permanent
        ]
      ],
      host_agent: [
        include_executables_for: [:unix],
        applications: [
          backplane_host_agent: :permanent,
          runtime_tools: :permanent
        ]
      ]
    ]
  end

  defp release(args) do
    case OptionParser.parse!(args, strict: release_switches(), aliases: [f: :force]) do
      {_opts, []} ->
        release_all(args)

      {_opts, [_name]} ->
        Mix.Task.run("release", args)

      {_opts, _extra} ->
        Mix.Task.run("release", args)
    end
  end

  defp release_all(args) do
    Enum.each(["backplane", "host_agent"], fn name ->
      Mix.Task.run("release", [name | args])
      Mix.Task.reenable("release")
    end)
  end

  defp release_switches do
    [
      overwrite: :boolean,
      force: :boolean,
      quiet: :boolean,
      path: :string,
      version: :string,
      compile: :boolean,
      deps_check: :boolean,
      archives_check: :boolean,
      elixir_version_check: :boolean
    ]
  end
end
