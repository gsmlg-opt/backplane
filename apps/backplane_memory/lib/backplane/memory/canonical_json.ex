defmodule Backplane.Memory.CanonicalJSON do
  @moduledoc false

  def encode(value) do
    case canonical_json(value) do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
      :error -> {:error, :not_json_safe}
    end
  end

  defp canonical_json(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(map, fn {key, _value} -> is_binary(key) and String.valid?(key) end) do
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, parts} ->
        case canonical_json(value) do
          {:ok, encoded} ->
            part = [Jason.encode!(key), ?:, encoded]
            {:cont, {:ok, [part | parts]}}

          :error ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, parts} -> {:ok, [?{, Enum.intersperse(Enum.reverse(parts), ?,), ?}]}
        :error -> :error
      end
    else
      :error
    end
  end

  defp canonical_json([]), do: {:ok, "[]"}

  defp canonical_json([head | tail]) do
    with {:ok, encoded_head} <- canonical_json(head),
         {:ok, encoded_tail} <- canonical_list(tail) do
      {:ok, [?[, Enum.intersperse([encoded_head | encoded_tail], ?,), ?]]}
    else
      :error -> :error
    end
  end

  defp canonical_json(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value) do
    if is_binary(value) and not String.valid?(value) do
      :error
    else
      case Jason.encode(value) do
        {:ok, encoded} -> {:ok, encoded}
        {:error, _reason} -> :error
      end
    end
  end

  defp canonical_json(_value), do: :error

  defp canonical_list([]), do: {:ok, []}

  defp canonical_list([head | tail]) do
    with {:ok, encoded_head} <- canonical_json(head),
         {:ok, encoded_tail} <- canonical_list(tail) do
      {:ok, [encoded_head | encoded_tail]}
    else
      :error -> :error
    end
  end

  defp canonical_list(_improper_tail), do: :error
end
