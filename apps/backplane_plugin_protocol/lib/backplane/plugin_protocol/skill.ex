defmodule Backplane.PluginProtocol.Skill do
  @moduledoc false
  alias Backplane.PluginProtocol.Manifest

  def parse(path, bytes, files) do
    with true <- String.valid?(bytes),
         [yaml, body] <-
           Regex.run(
             ~r/\A(?:\x{FEFF})?---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/su,
             bytes,
             capture: :all_but_first
           ),
         true <- byte_size(yaml) <= 262_144,
         {:ok, metadata} <- Formata.decode(yaml, :yaml),
         true <- is_map(metadata) and string_keys?(metadata),
         :ok <- validate(metadata, path) do
      root = Path.dirname(path)

      resources =
        Map.filter(files, fn {p, _} -> p != path and String.starts_with?(p, root <> "/") end)

      {:ok,
       %{
         path: path,
         root: root,
         name: metadata["name"],
         description: metadata["description"],
         content: bytes,
         body: body,
         metadata: metadata,
         files: resources
       }}
    else
      _ ->
        {:error,
         Manifest.diag(:error, :invalid_skill, path, "skill does not conform to Agent Skills")}
    end
  end

  defp string_keys?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)

  defp string_keys?(_value), do: true

  defp validate(data, path) do
    name = data["name"]

    valid =
      is_binary(name) and String.length(name) in 1..64 and
        Regex.match?(~r/\A[\p{Ll}\p{N}]+(?:-[\p{Ll}\p{N}]+)*\z/u, name) and
        name == Path.basename(Path.dirname(path)) and
        text?(data["description"], 1024) and
        optional?(data, "license", &is_binary/1) and
        optional?(data, "compatibility", &text?(&1, 500)) and
        optional?(data, "allowed-tools", &is_binary/1) and
        optional?(data, "metadata", fn value ->
          is_map(value) and Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end)
        end)

    if valid, do: :ok, else: :error
  end

  defp text?(value, max),
    do: is_binary(value) and String.length(value) in 1..max and String.trim(value) != ""

  defp optional?(data, key, validator), do: not Map.has_key?(data, key) or validator.(data[key])
end
