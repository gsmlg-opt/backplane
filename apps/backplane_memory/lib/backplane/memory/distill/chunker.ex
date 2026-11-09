defmodule Backplane.Memory.Distill.Chunker do
  @moduledoc """
  Renders a session's projected observations for the memory agent and packs them
  into chunks bounded by encoded JSON size.

  Observations are ordered by `source_sequence`; each `content` is truncated to
  4000 bytes (UTF-8 safe). Chunks are greedy-packed and never empty; an
  observation larger than `max_bytes` on its own forms a single-item chunk.
  """

  alias Backplane.Memory.Projections.ProjectedObservation

  @default_max_bytes 24_000
  @max_content_bytes 4_000

  @spec chunks([ProjectedObservation.t()], pos_integer()) :: [[map()]]
  def chunks(observations, max_bytes \\ @default_max_bytes)
      when is_list(observations) and is_integer(max_bytes) and max_bytes > 0 do
    observations
    |> Enum.sort_by(& &1.source_sequence)
    |> Enum.map(&render/1)
    |> pack(max_bytes)
  end

  defp render(%ProjectedObservation{} = o) do
    %{
      "event_id" => o.event_id,
      "at" => o.occurred_at && DateTime.to_iso8601(o.occurred_at),
      "type" => o.event_type,
      "tool" => o.tool_name,
      "content" => truncate(o.content || o.message || "")
    }
  end

  defp truncate(text) when byte_size(text) <= @max_content_bytes, do: text
  defp truncate(text), do: text |> binary_part(0, @max_content_bytes) |> valid_prefix()

  # Drops a trailing partial UTF-8 sequence left by the byte cut.
  defp valid_prefix(bin) do
    if String.valid?(bin), do: bin, else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # JSON array size = 2 brackets + items + (n - 1) commas.
  defp pack(items, max_bytes) do
    {chunks, current, _size} =
      Enum.reduce(items, {[], [], 2}, fn item, {chunks, current, size} ->
        item_size = byte_size(Jason.encode!(item))
        added = if current == [], do: item_size, else: item_size + 1

        if current != [] and size + added > max_bytes do
          {[Enum.reverse(current) | chunks], [item], 2 + item_size}
        else
          {chunks, [item | current], size + added}
        end
      end)

    chunks = if current == [], do: chunks, else: [Enum.reverse(current) | chunks]
    Enum.reverse(chunks)
  end
end
