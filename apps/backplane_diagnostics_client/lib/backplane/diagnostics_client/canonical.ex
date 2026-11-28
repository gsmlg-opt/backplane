defmodule Backplane.DiagnosticsClient.Canonical do
  @moduledoc "Stable JSON bytes and SHA-256 digests for diagnostics protocol v1."

  @max_depth 12
  @max_integer 9_007_199_254_740_991
  @max_bytes 64 * 1024

  def version, do: 1
  def max_bytes, do: @max_bytes

  @spec encode(term()) :: {:ok, binary()} | {:error, :invalid_json | :event_too_large}
  def encode(value) do
    iodata = encode_value(value, @max_depth)

    if :erlang.iolist_size(iodata) <= @max_bytes do
      {:ok, IO.iodata_to_binary(iodata)}
    else
      {:error, :event_too_large}
    end
  catch
    :invalid_diagnostics_json -> {:error, :invalid_json}
  end

  def digest(bytes) when is_binary(bytes),
    do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  def digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

  defp encode_value(_value, depth) when depth < 0, do: throw(:invalid_diagnostics_json)

  defp encode_value(value, depth) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort()
      |> Enum.map_intersperse(?,, fn {key, nested} ->
        [encode_string(key), ?:, encode_value(nested, depth - 1)]
      end)

    [?{, entries, ?}]
  end

  defp encode_value(value, depth) when is_list(value) do
    [?[, Enum.map_intersperse(value, ?,, &encode_value(&1, depth - 1)), ?]]
  end

  defp encode_value(value, _) when is_binary(value), do: encode_string(value)

  defp encode_value(value, _) when is_integer(value) and abs(value) <= @max_integer,
    do: Integer.to_string(value)

  defp encode_value(true, _), do: "true"
  defp encode_value(false, _), do: "false"
  defp encode_value(nil, _), do: "null"
  defp encode_value(_value, _), do: throw(:invalid_diagnostics_json)

  defp encode_string(value) when is_binary(value) and byte_size(value) <= @max_bytes do
    if String.valid?(value),
      do: Formata.JSON.encode!(value),
      else: throw(:invalid_diagnostics_json)
  end

  defp encode_string(_value), do: throw(:invalid_diagnostics_json)
end
