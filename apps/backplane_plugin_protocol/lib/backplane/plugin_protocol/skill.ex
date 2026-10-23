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
         {:ok, pairs} <- YamlElixir.read_from_string(yaml, maps_as_keywords: true),
         {:ok, _} <- mapping(pairs),
         {:ok, metadata} <- YamlElixir.read_from_string(yaml),
         true <- is_map(metadata),
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

  defp mapping(pairs) when is_list(pairs) and pairs != [] do
    if Enum.all?(pairs, &match?({key, _} when is_binary(key), &1)) and
         length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case convert(value) do
          {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp mapping(_), do: :error

  defp convert(value) when is_list(value) do
    if Enum.any?(value, &is_tuple/1), do: mapping(value), else: {:ok, value}
  end

  defp convert(value), do: {:ok, value}

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
