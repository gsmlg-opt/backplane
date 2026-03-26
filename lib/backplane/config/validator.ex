defmodule Backplane.Config.Validator do
  @moduledoc """
  Validates parsed configuration at startup, catching misconfigurations
  early rather than failing on first request.
  """

  require Logger

  @doc """
  Validates config and returns a list of warnings.
  Raises on fatal errors.
  """
  @spec validate!(keyword()) :: :ok
  def validate!(config) do
    warnings =
      []
      |> validate_upstreams(config[:upstream] || [])
      |> validate_projects(config[:projects] || [])
      |> validate_skills(config[:skills] || [])
      |> validate_port(config[:backplane])

    for warning <- warnings do
      Logger.warning("Config: #{warning}")
    end

    :ok
  end

  defp validate_upstreams(warnings, upstreams) do
    Enum.reduce(upstreams, warnings, fn upstream, acc ->
      acc
      |> check_required(upstream, :name, "upstream")
      |> check_required(upstream, :prefix, "upstream #{upstream[:name]}")
      |> check_required(upstream, :transport, "upstream #{upstream[:name]}")
      |> check_upstream_transport(upstream)
    end)
  end

  defp check_upstream_transport(warnings, %{transport: "http"} = upstream) do
    check_required(warnings, upstream, :url, "upstream #{upstream[:name]} (http)")
  end

  defp check_upstream_transport(warnings, %{transport: "stdio"} = upstream) do
    check_required(warnings, upstream, :command, "upstream #{upstream[:name]} (stdio)")
  end

  defp check_upstream_transport(warnings, %{transport: transport, name: name})
       when is_binary(transport) do
    ["upstream #{name}: unknown transport '#{transport}' (expected 'http' or 'stdio')" | warnings]
  end

  defp check_upstream_transport(warnings, _upstream), do: warnings

  defp validate_projects(warnings, projects) do
    Enum.reduce(projects, warnings, fn project, acc ->
      acc
      |> check_required(project, :id, "project")
      |> check_required(project, :repo, "project #{project[:id]}")
    end)
  end

  defp validate_skills(warnings, skills) do
    Enum.reduce(skills, warnings, fn skill, acc ->
      acc
      |> check_required(skill, :name, "skill")
      |> check_required(skill, :source, "skill #{skill[:name]}")
      |> check_skill_source(skill)
    end)
  end

  defp check_skill_source(warnings, %{source: "git"} = skill) do
    check_required(warnings, skill, :repo, "skill #{skill[:name]} (git)")
  end

  defp check_skill_source(warnings, %{source: "local"} = skill) do
    check_required(warnings, skill, :path, "skill #{skill[:name]} (local)")
  end

  defp check_skill_source(warnings, %{source: source, name: name})
       when is_binary(source) do
    ["skill #{name}: unknown source '#{source}' (expected 'git' or 'local')" | warnings]
  end

  defp check_skill_source(warnings, _skill), do: warnings

  defp validate_port(warnings, %{port: port})
       when is_integer(port) and port > 0 and port < 65_536 do
    warnings
  end

  defp validate_port(warnings, %{port: port}) do
    ["invalid port #{inspect(port)}, must be 1-65535" | warnings]
  end

  defp validate_port(warnings, _), do: warnings

  defp check_required(warnings, map, key, context) do
    case Map.get(map, key) do
      nil -> ["#{context}: missing required field '#{key}'" | warnings]
      "" -> ["#{context}: '#{key}' cannot be empty" | warnings]
      _ -> warnings
    end
  end
end
