defmodule Backplane.Memory.Memories.CanonicalRequest do
  @moduledoc false

  alias Backplane.Memory.CanonicalJSON
  alias Backplane.Memory.Memories.Attribution

  def hash(attrs, evidence \\ []) when is_map(attrs) and is_list(evidence) do
    request = %{
      "content" => attrs.content,
      "memory_type" => attrs.memory_type,
      "scope" => attrs.scope,
      "namespace" => attrs.namespace,
      "project" => Attribution.project(attrs.metadata),
      "client_id" => attrs.client_id,
      "agent_id" => attrs.agent_id,
      "host_id" => attrs.host_id,
      "session_id" => attrs.session_id,
      "tags" => attrs.tags,
      "metadata" => attrs.metadata |> Attribution.metadata_without_project() |> normalize()
    }

    with {:ok, canonical_evidence} <- canonical_evidence(evidence),
         request =
           if(canonical_evidence == [],
             do: request,
             else: Map.put(request, "evidence", canonical_evidence)
           ),
         {:ok, encoded} <- CanonicalJSON.encode(request) do
      {:ok, :crypto.hash(:sha256, encoded)}
    end
  end

  defp canonical_evidence(evidence) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, encoded_items} ->
      normalized = normalize(item)

      case CanonicalJSON.encode(normalized) do
        {:ok, encoded} -> {:cont, {:ok, [{encoded, normalized} | encoded_items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded_items} ->
        {:ok, encoded_items |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}

      error ->
        error
    end
  end

  defp normalize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize(value), do: value
end
