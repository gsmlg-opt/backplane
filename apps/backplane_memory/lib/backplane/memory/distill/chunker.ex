defmodule Backplane.Memory.Distill.Chunker do
  @moduledoc """
  Renders a session's projected observations for the memory agent and packs them
  into chunks bounded by encoded JSON size.

  Observations are ordered by `source_sequence`; each `content` is truncated to
  4000 bytes (UTF-8 safe). Each item is a `ProjectedObservation` or a
  `{ProjectedObservation, tool_input}` tuple; a present tool input is rendered as
  `"input"` (compact JSON, truncated to 1500 bytes), a failed observation carries
  `"error" => true` and non-empty file paths are rendered as `"files"`.
  Observations whose content is only their event type and that have no input carry
  nothing for the agent and are dropped. Chunks are greedy-packed and never empty;
  an observation larger than `max_bytes` on its own forms a single-item chunk.
  """

  alias Backplane.Memory.Projections.ProjectedObservation

  @default_max_bytes 24_000
  @max_content_bytes 4_000
  @max_input_bytes 1_500

  @type item :: ProjectedObservation.t() | {ProjectedObservation.t(), term()}

  @spec chunks([item()], pos_integer()) :: [[map()]]
  def chunks(observations, max_bytes \\ @default_max_bytes)
      when is_list(observations) and is_integer(max_bytes) and max_bytes > 0 do
    observations
    |> Enum.map(&with_input/1)
    |> Enum.reject(&bare?/1)
    |> Enum.sort_by(fn {o, _input} -> o.source_sequence end)
    |> Enum.map(&render/1)
    |> pack(max_bytes)
  end

  defp with_input({%ProjectedObservation{} = o, input}), do: {o, blank_to_nil(input)}
  defp with_input(%ProjectedObservation{} = o), do: {o, nil}

  defp blank_to_nil(input) when input in [nil, "", %{}, []], do: nil
  defp blank_to_nil(input), do: input

  defp bare?({o, nil}), do: content(o) == o.event_type
  defp bare?({_o, _input}), do: false

  defp render({%ProjectedObservation{} = o, input}) do
    %{
      "event_id" => o.event_id,
      "at" => o.occurred_at && DateTime.to_iso8601(o.occurred_at),
      "type" => o.event_type,
      "tool" => o.tool_name,
      "content" => o |> content() |> truncate(@max_content_bytes)
    }
    |> put_input(input)
    |> put_if(o.is_error == true, "error", true)
    |> put_if(o.file_paths not in [nil, []], "files", o.file_paths)
  end

  defp content(o), do: o.content || o.message || ""

  defp put_input(map, nil), do: map

  defp put_input(map, input) when is_binary(input),
    do: Map.put(map, "input", truncate(input, @max_input_bytes))

  defp put_input(map, input), do: put_input(map, Jason.encode!(input))

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: text |> binary_part(0, max) |> valid_prefix()

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
