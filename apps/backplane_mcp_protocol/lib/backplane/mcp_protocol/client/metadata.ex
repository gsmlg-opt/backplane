defmodule Backplane.McpProtocol.Client.Metadata do
  @moduledoc false

  alias Backplane.McpProtocol.Client.State

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @log_level_key "io.modelcontextprotocol/logLevel"
  @log_levels ~w(debug info notice warning error critical alert emergency)

  @spec attach(map(), State.t() | map(), map()) :: map()
  def attach(params, state, extra_meta) when is_map(params) and is_map(state) do
    existing_meta = existing_metadata(params)
    extra_meta = sanitize_object(extra_meta)
    metadata = Map.merge(existing_meta, extra_meta)
    metadata_present? = Map.has_key?(params, "_meta") or Map.has_key?(params, :_meta)
    params = Map.delete(params, :_meta)

    case Map.get(state, :era) do
      :modern ->
        client_info = sanitize_object(Map.get(state, :client_info))
        capabilities = sanitize_object(Map.get(state, :capabilities))

        metadata =
          metadata
          |> maybe_put_client_info(client_info)
          |> maybe_put_log_level(Map.get(state, :log_level))
          |> Map.put(@client_capabilities_key, capabilities)
          |> Map.put(@protocol_version_key, Map.get(state, :protocol_version))

        Map.put(params, "_meta", metadata)

      _legacy_or_unknown ->
        if map_size(metadata) == 0 and not metadata_present? do
          params
        else
          Map.put(params, "_meta", metadata)
        end
    end
  end

  defp maybe_put_client_info(metadata, client_info) do
    if valid_implementation?(client_info) do
      Map.put(metadata, @client_info_key, client_info)
    else
      Map.delete(metadata, @client_info_key)
    end
  end

  defp maybe_put_log_level(metadata, level) when level in @log_levels do
    Map.put(metadata, @log_level_key, level)
  end

  defp maybe_put_log_level(metadata, _level), do: Map.delete(metadata, @log_level_key)

  defp valid_implementation?(%{} = info) do
    is_binary(info["name"]) and
      is_binary(info["version"]) and
      valid_optional_string?(info, "title") and
      valid_optional_string?(info, "description") and
      valid_optional_absolute_uri?(info, "websiteUrl") and
      valid_optional_icons?(info)
  end

  defp valid_implementation?(_info), do: false

  defp valid_optional_string?(container, field) do
    valid_optional_field?(container, field, &is_binary/1)
  end

  defp valid_optional_absolute_uri?(container, field) do
    valid_optional_field?(container, field, &absolute_uri?/1)
  end

  defp valid_optional_icons?(info) do
    valid_optional_field?(info, "icons", fn
      icons when is_list(icons) -> Enum.all?(icons, &valid_icon?/1)
      _invalid -> false
    end)
  end

  defp valid_icon?(%{} = icon) do
    absolute_uri?(icon["src"]) and
      valid_optional_string?(icon, "mimeType") and
      valid_optional_field?(icon, "sizes", &string_list?/1) and
      valid_optional_field?(icon, "theme", &(&1 in ~w(light dark)))
  end

  defp valid_icon?(_icon), do: false

  defp valid_optional_field?(container, field, validator) do
    case Map.fetch(container, field) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp absolute_uri?(value) when is_binary(value) do
    match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
  end

  defp absolute_uri?(_value), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp existing_metadata(params) do
    params
    |> Map.get(:_meta)
    |> sanitize_object()
    |> Map.merge(params |> Map.get("_meta") |> sanitize_object())
  end

  defp sanitize_object(value) when is_map(value), do: sanitize_json(value)
  defp sanitize_object(_value), do: %{}

  defp sanitize_json(value) when is_map(value) do
    {string_entries, other_entries} = Enum.split_with(value, fn {key, _nested} -> is_binary(key) end)

    other_entries
    |> Enum.concat(string_entries)
    |> Enum.reduce(%{}, fn {key, nested}, acc ->
      Map.put(acc, stringify_key(key), sanitize_json(nested))
    end)
  end

  defp sanitize_json(value) when is_list(value), do: Enum.map(value, &sanitize_json/1)
  defp sanitize_json(value), do: value

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_integer(key), do: Integer.to_string(key)
  defp stringify_key(key), do: inspect(key)
end
