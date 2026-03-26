defmodule Backplane.Config do
  @moduledoc """
  Loads and parses the backplane.toml configuration file.
  """

  @default_port 4100
  @default_host "0.0.0.0"
  @default_ref "main"
  @default_parsers ["generic"]
  @default_github_api_url "https://api.github.com"
  @default_gitlab_api_url "https://gitlab.com/api/v4"

  @doc """
  Loads configuration from a TOML file path.

  Returns a keyword list with parsed configuration sections:
  - `:backplane` — host, port, auth_token
  - `:database` — url
  - `:github` — list of {name, token, api_url}
  - `:gitlab` — list of {name, token, api_url}
  - `:projects` — list of project configs
  - `:upstream` — list of upstream MCP server configs
  - `:skills` — list of skill source configs
  """
  @spec load!(String.t()) :: keyword()
  def load!(path) do
    unless File.exists?(path) do
      raise "Config file not found: #{path}"
    end

    case Toml.decode_file(path) do
      {:ok, raw} ->
        parse(raw)

      {:error, reason} ->
        raise "Failed to parse config file #{path}: #{inspect(reason)}"
    end
  end

  defp parse(raw) do
    [
      backplane: parse_backplane(raw["backplane"] || %{}),
      database: parse_database(raw["database"] || %{}),
      github: parse_git_providers(raw, "github", @default_github_api_url),
      gitlab: parse_git_providers(raw, "gitlab", @default_gitlab_api_url),
      projects: parse_projects(raw["projects"] || []),
      upstream: parse_upstreams(raw["upstream"] || []),
      skills: parse_skills(raw["skills"] || [])
    ]
  end

  defp parse_backplane(section) do
    %{
      host: section["host"] || @default_host,
      port: section["port"] || @default_port,
      auth_token: section["auth_token"]
    }
  end

  defp parse_database(section) do
    %{
      url: section["url"]
    }
  end

  defp parse_git_providers(raw, prefix, default_api_url) do
    case raw[prefix] do
      nil ->
        []

      section when is_map(section) ->
        # The top-level section has token + api_url for the "default" instance
        # Nested maps are additional named instances
        default_entry =
          if Map.has_key?(section, "token") do
            [
              %{
                name: "default",
                token: section["token"],
                api_url: section["api_url"] || default_api_url
              }
            ]
          else
            []
          end

        nested_entries =
          section
          |> Enum.filter(fn {_key, val} -> is_map(val) and Map.has_key?(val, "token") end)
          |> Enum.map(fn {name, val} ->
            %{
              name: name,
              token: val["token"],
              api_url: val["api_url"] || default_api_url
            }
          end)

        default_entry ++ nested_entries

      _ ->
        []
    end
  end

  defp parse_projects(projects) when is_list(projects) do
    Enum.map(projects, fn proj ->
      %{
        id: proj["id"],
        repo: proj["repo"],
        ref: proj["ref"] || @default_ref,
        parsers: proj["parsers"] || @default_parsers,
        reindex_interval: proj["reindex_interval"] || "1h",
        webhook_secret: proj["webhook_secret"]
      }
    end)
  end

  defp parse_projects(_), do: []

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, fn up ->
      base = %{
        name: up["name"],
        transport: up["transport"],
        prefix: up["prefix"],
        timeout: up["timeout"],
        refresh_interval: up["refresh_interval"]
      }

      case up["transport"] do
        "stdio" ->
          Map.merge(base, %{
            command: up["command"],
            args: up["args"] || [],
            env: parse_env(up["env"])
          })

        "http" ->
          Map.merge(base, %{
            url: up["url"],
            headers: up["headers"] || %{}
          })

        _ ->
          base
      end
    end)
  end

  defp parse_upstreams(_), do: []

  defp parse_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      base = %{
        name: skill["name"],
        source: skill["source"],
        path: skill["path"]
      }

      case skill["source"] do
        "git" ->
          Map.merge(base, %{
            repo: skill["repo"],
            ref: skill["ref"] || @default_ref,
            sync_interval: skill["sync_interval"] || "1h"
          })

        "local" ->
          base

        _ ->
          base
      end
    end)
  end

  defp parse_skills(_), do: []

  defp parse_env(nil), do: %{}
  defp parse_env(env) when is_map(env), do: env
  defp parse_env(_), do: %{}
end
