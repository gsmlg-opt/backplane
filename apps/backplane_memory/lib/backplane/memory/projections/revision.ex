defmodule Backplane.Memory.Projections.Revision do
  @moduledoc "Deterministic revisions for projection inputs and JSON-safe outputs."

  alias Backplane.Memory.CanonicalJSON
  alias Backplane.Memory.Projections.EventOrder

  def input_revision(events) when is_list(events) do
    events
    |> EventOrder.sort()
    |> Enum.map(&[&1.id, &1.payload_hash, &1.source_sequence, &1.event_type])
    |> canonical_json!()
    |> digest()
  end

  def output_revision(output) do
    case CanonicalJSON.encode(output) do
      {:ok, encoded} -> {:ok, digest(encoded)}
      {:error, :not_json_safe} = error -> error
    end
  end

  defdelegate encode_json(value), to: CanonicalJSON, as: :encode

  defp canonical_json!(value) do
    {:ok, encoded} = CanonicalJSON.encode(value)
    encoded
  end

  defp digest(iodata) do
    :sha256
    |> :crypto.hash(iodata)
    |> Base.encode16(case: :lower)
  end
end
