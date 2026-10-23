defmodule Backplane.PluginProtocol.MCP do
  @moduledoc "Validation of portable MCP declarations. Values remain unexpanded until runtime."
  alias Backplane.PluginProtocol.{Manifest, Path}
  @schema "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"

  def discover(nil, _opts), do: {%{}, []}

  def discover(bytes, opts) do
    case JSON.decode(bytes) do
      {:ok, %{"$schema" => @schema, "mcpServers" => servers} = config}
      when is_map(servers) and map_size(config) == 2 ->
        Enum.reduce(Enum.sort(servers), {%{}, []}, fn {name, server}, {valid, diagnostics} ->
          path = "mcp.json#/mcpServers/" <> name

          cond do
            not valid?(server) ->
              {valid,
               diagnostics ++
                 [
                   Manifest.diag(
                     :error,
                     :invalid_mcp_server,
                     path,
                     "invalid MCP server declaration"
                   )
                 ]}

            server["type"] not in Keyword.get(opts, :transports, ~w(stdio streamable-http sse)) ->
              {valid,
               diagnostics ++
                 [
                   Manifest.diag(
                     :warning,
                     :unsupported_transport,
                     path,
                     "unsupported MCP transport"
                   )
                 ]}

            true ->
              {Map.put(valid, name, server), diagnostics}
          end
        end)

      _ ->
        {%{},
         [
           Manifest.diag(
             :error,
             :invalid_mcp_config,
             "mcp.json",
             "invalid or unsupported MCP configuration"
           )
         ]}
    end
  end

  def valid?(%{"type" => "stdio", "command" => command} = config) do
    closed?(config, ~w(type command args env cwd)) and command?(command) and
      optional?(config, "args", &strings?/1) and optional?(config, "env", &environment?/1) and
      optional?(config, "cwd", &cwd?/1)
  end

  def valid?(%{"type" => type, "url" => url} = config) when type in ["streamable-http", "sse"] do
    closed?(config, ~w(type url headers)) and url?(url) and
      optional?(config, "headers", &headers?/1)
  end

  def valid?(_), do: false

  defp command?(command) when is_binary(command) and command != "" do
    not String.contains?(command, ["${", "\0", "\r", "\n", "\t", " ", "\\"]) and
      if String.starts_with?(command, "./"),
        do: Path.contained?(String.slice(command, 2..-1//1)),
        else: not String.contains?(command, ["/", ":"])
  end

  defp command?(_), do: false

  defp cwd?(cwd) when is_binary(cwd) do
    Enum.any?(["./", "${PLUGIN_ROOT}", "${PLUGIN_DATA}"], fn prefix ->
      cond do
        prefix == "./" and String.starts_with?(cwd, prefix) ->
          Path.contained?(String.slice(cwd, 2..-1//1))

        cwd == prefix ->
          true

        String.starts_with?(cwd, prefix <> "/") ->
          Path.contained?(String.replace_prefix(cwd, prefix <> "/", ""))

        true ->
          false
      end
    end)
  end

  defp cwd?(_), do: false

  defp environment?(env) do
    string_map?(env) and
      Enum.all?(env, fn {key, value} ->
        key not in ["PLUGIN_ROOT", "PLUGIN_DATA"] and key != "" and
          not String.contains?(key, ["=", "\0"]) and not String.contains?(value, "\0")
      end)
  end

  defp headers?(headers) do
    string_map?(headers) and
      length(Enum.uniq(Enum.map(Map.keys(headers), &String.downcase/1))) == map_size(headers) and
      Enum.all?(headers, fn {key, value} ->
        Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9a-zA-Z-]+\z/, key) and
          Enum.all?(:binary.bin_to_list(value), &(&1 == 9 or (&1 >= 32 and &1 != 127)))
      end)
  end

  defp url?(url) when is_binary(url) do
    with {:ok, uri} <- URI.new(url) do
      uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        uri.port in 1..65_535 and is_nil(uri.userinfo) and is_nil(uri.fragment) and
        not Regex.match?(~r/[\s\x00-\x1f]/, url) and
        (uri.scheme == "https" or loopback?(uri.host))
    else
      _ -> false
    end
  end

  defp url?(_), do: false

  defp loopback?("localhost"), do: true

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 65535, high, _}} when high in 32512..32767 -> true
      _ -> false
    end
  end

  defp strings?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp string_map?(value),
    do: is_map(value) and Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp optional?(config, key, validator),
    do: not Map.has_key?(config, key) or validator.(config[key])

  defp closed?(config, keys), do: Enum.all?(Map.keys(config), &(&1 in keys))
end
