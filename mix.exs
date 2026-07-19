defmodule Backplane.Umbrella.MixProject do
  use Mix.Project

  @version "0.4.1"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      release: &release/1,
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app backplane_system cmd mix ecto.setup"],
      "ecto.reset": ["do --app backplane_system cmd mix ecto.reset"],
      "ecto.migrate": ["do --app backplane_system cmd mix ecto.migrate"],
      "backplane.run": ["phx.server"],
      "agent.run": [
        "do --app backplane_host_agent cmd mix agent.run"
      ],
      "assets.deploy": [
        "do --app backplane_api assets.deploy",
        "do --app backplane_admin assets.deploy"
      ],
      test: ["test"]
    ]
  end

  defp releases do
    [
      backplane: [
        include_executables_for: [:unix],
        applications: [
          backplane: :permanent,
          backplane_auth: :permanent,
          backplane_api: :permanent,
          backplane_admin: :permanent,
          backplane_memory: :permanent,
          runtime_tools: :permanent
        ]
      ],
      host_agent: [
        include_executables_for: [:unix],
        runtime_config_path: "config/host_agent_runtime.exs",
        steps: [:assemble, &copy_host_agent_integrations/1],
        applications: [
          backplane_host_agent: :permanent,
          runtime_tools: :permanent
        ]
      ]
    ]
  end

  defp copy_host_agent_integrations(release) do
    destination =
      Path.join([
        release.path,
        "lib",
        "backplane_host_agent-#{release.version}",
        "priv",
        "integrations",
        "memory"
      ])

    File.rm_rf!(destination)
    File.mkdir_p!(Path.dirname(destination))
    File.cp_r!("integrations/memory", destination)

    release
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
