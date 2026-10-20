defmodule Backplane.Config.Validator do
  @moduledoc """
  Validates parsed configuration at startup, catching misconfigurations
  early rather than failing on first request.
  """

  require Logger

  alias Backplane.Registry.Namespace

  @doc """
  Validates config and returns a list of warning strings.
  """
  @spec validate(keyword()) :: [String.t()]
  def validate(config) do
    []
    |> validate_upstreams(config[:upstream] || [])
    |> validate_port(config[:backplane])
  end

  @doc """
  Validates config, logs warnings, and returns :ok.
  """
  @spec validate!(keyword()) :: :ok
  def validate!(config) do
    validate_client_credentials!(config)

    for warning <- validate(config) do
      Logger.warning("Config: #{warning}")
    end

    :ok
  end

  @doc false
  def validate_client_credentials!(config) do
    backplane = config[:backplane] || %{}

    for key <- [:auth_token, :auth_tokens] do
      if value(backplane, key) not in [nil, "", []] do
        raise ArgumentError, "Deprecated client credential configuration: #{key}"
      end
    end

    seeds = config[:clients] || []

    unless is_list(seeds) do
      raise ArgumentError, "Invalid clients configuration: expected metadata-only list"
    end

    for seed <- seeds do
      unless is_map(seed) do
        raise ArgumentError, "Invalid clients configuration: expected metadata-only map"
      end

      for key <- [:token, :token_hash, :token_digest, :scheme, :credential_scheme] do
        if Map.has_key?(seed, key) or Map.has_key?(seed, Atom.to_string(key)) do
          raise ArgumentError, "Deprecated clients credential configuration: #{key}"
        end
      end
    end

    :ok
  end

  @doc false
  def validate_runtime_client_credentials! do
    for name <- ["BACKPLANE_AUTH_TOKEN", "BACKPLANE_AUTH_TOKENS"] do
      if System.get_env(name) not in [nil, ""] do
        raise ArgumentError, "Deprecated client credential environment variable: #{name}"
      end
    end

    validate_client_credentials!(
      backplane: %{
        auth_token: Application.get_env(:backplane, :auth_token),
        auth_tokens: Application.get_env(:backplane, :auth_tokens)
      },
      clients: Application.get_env(:backplane, :client_seeds, [])
    )
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validate_upstreams(warnings, upstreams) do
    warnings
    |> check_duplicates(upstreams, :prefix, "upstream prefix", &Namespace.normalize_prefix/1)
    |> check_duplicates(upstreams, :name, "upstream name")
    |> then(fn w ->
      Enum.reduce(upstreams, w, fn upstream, acc ->
        acc
        |> check_required(upstream, :name, "upstream")
        |> check_required(upstream, :prefix, "upstream #{upstream[:name]}")
        |> check_prefix_format(upstream)
        |> check_reserved_prefix(upstream)
        |> check_required(upstream, :transport, "upstream #{upstream[:name]}")
        |> check_upstream_transport(upstream)
      end)
    end)
  end

  defp check_prefix_format(warnings, %{prefix: prefix, name: name}) when is_binary(prefix) do
    prefix = Namespace.normalize_prefix(prefix)

    cond do
      prefix == "" ->
        warnings

      Namespace.valid_prefix?(prefix) ->
        warnings

      true ->
        [
          "upstream #{name}: 'prefix' can contain only letters, numbers, underscores, and hyphens"
          | warnings
        ]
    end
  end

  defp check_prefix_format(warnings, _upstream), do: warnings

  defp check_reserved_prefix(warnings, %{prefix: prefix, name: name}) when is_binary(prefix) do
    prefix = Namespace.normalize_prefix(prefix)

    if Namespace.reserved_prefix?(prefix) do
      ["upstream #{name}: prefix '#{prefix}' is reserved for a built-in service" | warnings]
    else
      warnings
    end
  end

  defp check_reserved_prefix(warnings, _upstream), do: warnings

  defp check_upstream_transport(warnings, %{transport: "http"} = upstream) do
    warnings
    |> check_required(upstream, :url, "upstream #{upstream[:name]} (http)")
    |> check_positive_integer(upstream, :timeout, "upstream #{upstream[:name]}")
    |> check_positive_integer(upstream, :refresh_interval, "upstream #{upstream[:name]}")
  end

  defp check_upstream_transport(warnings, %{transport: "stdio"} = upstream) do
    warnings
    |> check_required(upstream, :command, "upstream #{upstream[:name]} (stdio)")
    |> check_positive_integer(upstream, :timeout, "upstream #{upstream[:name]}")
    |> check_positive_integer(upstream, :refresh_interval, "upstream #{upstream[:name]}")
  end

  defp check_upstream_transport(warnings, %{transport: transport, name: name})
       when is_binary(transport) do
    ["upstream #{name}: unknown transport '#{transport}' (expected 'http' or 'stdio')" | warnings]
  end

  defp check_upstream_transport(warnings, _upstream), do: warnings

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

  defp check_positive_integer(warnings, map, key, context) do
    case Map.get(map, key) do
      nil -> warnings
      val when is_integer(val) and val > 0 -> warnings
      val -> ["#{context}: '#{key}' must be a positive integer, got #{inspect(val)}" | warnings]
    end
  end

  defp check_duplicates(warnings, items, key, label, normalize \\ fn value -> value end) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.map(normalize)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_val, count} -> count > 1 end)
    |> Enum.reduce(warnings, fn {val, count}, acc ->
      ["duplicate #{label} '#{val}' appears #{count} times" | acc]
    end)
  end
end
