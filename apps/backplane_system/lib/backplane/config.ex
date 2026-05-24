defmodule Backplane.Config do
  @moduledoc """
  Loads and parses the backplane.toml configuration file.
  """

  @default_port 4100
  @default_host "0.0.0.0"

  @doc """
  Loads configuration from a TOML file path.

  Returns a keyword list with parsed configuration sections:
  - `:backplane` — host, port, auth_token
  - `:database` — url
  - `:upstream` — list of upstream MCP server configs
  - `:clients` — list of pre-seeded client configs
  - `:cache` — cache settings
  - `:audit` — audit settings
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
      upstream: parse_upstreams(raw["upstream"] || []),
      clients: parse_clients(raw["clients"] || []),
      cache: parse_cache(raw["cache"] || %{}),
      audit: parse_audit(raw["audit"] || %{})
    ]
  end

  defp parse_backplane(section) do
    %{
      host: section["host"] || @default_host,
      port: section["port"] || @default_port,
      auth_token: section["auth_token"],
      auth_tokens: section["auth_tokens"],
      admin_username: section["admin_username"],
      admin_password: section["admin_password"]
    }
  end

  defp parse_database(section) do
    %{
      url: section["url"]
    }
  end

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, fn up ->
      base = %{
        name: up["name"],
        transport: up["transport"],
        prefix: up["prefix"],
        timeout: up["timeout"],
        refresh_interval: up["refresh_interval"],
        cache_ttl: up["cache_ttl"],
        cache_tools: up["cache_tools"]
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

  defp parse_audit(section) do
    %{
      enabled: section["enabled"] != false,
      retention_days: section["retention_days"] || 30
    }
  end

  defp parse_cache(section) do
    %{
      enabled: section["enabled"] != false,
      max_entries: section["max_entries"] || 10_000,
      default_ttl: section["default_ttl"] || "5m"
    }
  end

  defp parse_clients(clients) when is_list(clients) do
    Enum.map(clients, fn client ->
      %{
        name: client["name"],
        token: client["token"],
        scopes: client["scopes"] || []
      }
    end)
  end

  defp parse_clients(_), do: []

  defp parse_env(nil), do: %{}
  defp parse_env(env) when is_map(env), do: env
  defp parse_env(_), do: %{}
end
