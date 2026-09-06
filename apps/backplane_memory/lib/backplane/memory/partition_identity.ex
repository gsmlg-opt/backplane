defmodule Backplane.Memory.PartitionIdentity do
  @moduledoc """
  Validates canonical Memory V2 ownership at application boundaries.

  A memory space owns data. Host and client identities are provenance only and
  may not replace or contradict the canonical space, scope, and namespace.
  """

  @canonical_keys [:memory_space_id, :scope, :namespace]
  @optional_keys [:host_id, :source_client_id, :client_id]
  @known_keys @canonical_keys ++ @optional_keys

  @type error_reason :: :incomplete_partition | :partition_mismatch

  @spec validate(map()) :: {:ok, map()} | {:error, error_reason()}
  def validate(partition) when is_map(partition) do
    with :ok <- reject_duplicate_mismatch(partition),
         {:ok, memory_space_id} <- required_uuid(value(partition, :memory_space_id)),
         {:ok, scope} <- required_string(value(partition, :scope)),
         {:ok, namespace} <- required_string(value(partition, :namespace)) do
      validated =
        partition
        |> normalized_optional_fields()
        |> Map.merge(%{
          memory_space_id: memory_space_id,
          scope: scope,
          namespace: namespace
        })

      {:ok, validated}
    end
  end

  def validate(_partition), do: {:error, :incomplete_partition}

  @doc false
  @spec validate(map(), map()) :: {:ok, map()} | {:error, error_reason()}
  def validate(partition, expected_partition) do
    with {:ok, validated} <- validate(partition),
         {:ok, expected} <- validate(expected_partition),
         true <- canonical_identity(validated) == canonical_identity(expected) do
      {:ok, Map.merge(validated, canonical_identity(expected))}
    else
      false -> {:error, :partition_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_duplicate_mismatch(partition) do
    mismatch? =
      Enum.any?(@known_keys, fn key ->
        atom_present? = Map.has_key?(partition, key)
        string_key = Atom.to_string(key)
        string_present? = Map.has_key?(partition, string_key)

        atom_present? and string_present? and
          Map.get(partition, key) != Map.get(partition, string_key)
      end)

    if mismatch?, do: {:error, :partition_mismatch}, else: :ok
  end

  defp normalized_optional_fields(partition) do
    @optional_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case optional_string(value(partition, key)) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp canonical_identity(partition), do: Map.take(partition, @canonical_keys)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp required_uuid(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} when uuid == trimmed -> {:ok, uuid}
      _ -> {:error, :incomplete_partition}
    end
  end

  defp required_uuid(_value), do: {:error, :incomplete_partition}

  defp required_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :incomplete_partition}
      normalized -> {:ok, normalized}
    end
  end

  defp required_string(_value), do: {:error, :incomplete_partition}

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp optional_string(_value), do: nil
end
