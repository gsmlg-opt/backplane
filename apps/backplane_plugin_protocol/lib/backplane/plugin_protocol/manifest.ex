defmodule Backplane.PluginProtocol.Manifest do
  @moduledoc false
  @schema "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
  @fields ~w($schema name version description author homepage repository license keywords extensions)

  def schema, do: @schema

  def validate(manifest) when is_map(manifest) do
    errors =
      Enum.flat_map(manifest, fn {key, value} ->
        if key in @fields and key != "extensions" and not valid_field?(key, value),
          do: [diag(:error, :invalid_manifest_field, "plugin.json", "invalid #{key}")],
          else: []
      end) ++
        for key <- ["$schema", "name"],
            not Map.has_key?(manifest, key),
            do: diag(:error, :missing_manifest_field, "plugin.json", "missing #{key}")

    warnings =
      for key <- Map.keys(manifest) -- @fields,
          do:
            diag(
              :warning,
              :unknown_manifest_field,
              "plugin.json",
              "ignoring unknown field #{key}"
            )

    warnings =
      if Map.has_key?(manifest, "extensions") and not is_map(manifest["extensions"]),
        do:
          warnings ++
            [diag(:warning, :invalid_extensions, "plugin.json", "ignoring non-object extensions")],
        else: warnings

    if errors == [], do: {:ok, warnings}, else: {:error, errors ++ warnings}
  end

  def validate(_),
    do: {:error, [diag(:error, :invalid_manifest, "plugin.json", "manifest must be an object")]}

  def valid_name?(name) when is_binary(name) do
    byte_size(name) in 1..64 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, name) and
      not String.contains?(name, ["--", ".."])
  end

  def valid_name?(_), do: false

  def diag(severity, code, path, message),
    do: %{severity: severity, code: code, path: path, message: message}

  defp valid_field?("$schema", value), do: value == @schema
  defp valid_field?("name", value), do: valid_name?(value)

  defp valid_field?("author", value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> key in ~w(name email url) and is_binary(item) end)

  defp valid_field?("author", _), do: false
  defp valid_field?("keywords", value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp valid_field?(_, value), do: is_binary(value)
end
