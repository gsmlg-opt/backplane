defmodule Backplane.HostAgent.Memory.ContextPacker do
  @moduledoc "Whole-entry final recall packing after canonical/provisional merge."

  # UTF-8 bytes conservatively bound byte-tokenizer tokens, including every label,
  # identity, revision and separator. This matches Hermes's final context renderer.
  def pack(rows, budget) do
    {selected, lines, used, _seen} =
      Enum.reduce(rows, {[], [], 0, MapSet.new()}, fn row, {selected, lines, used, seen} = acc ->
        identity = {row["canonical_id"] || row["id"], row["revision"]}
        line = render(row, identity)
        cost = byte_size(line) + if(lines == [], do: 0, else: 1)

        if MapSet.member?(seen, identity) or used + cost > budget do
          acc
        else
          {[row | selected], [line | lines], used + cost, MapSet.put(seen, identity)}
        end
      end)

    %{
      results: Enum.reverse(selected),
      rendered_context: lines |> Enum.reverse() |> Enum.join("\n"),
      used_tokens: used,
      token_budget: budget
    }
  end

  defp render(row, {id, revision}) do
    label =
      case row["trust"] do
        "established_fact" -> "established fact"
        "raw_evidence" -> "raw evidence"
        _ -> "candidate inference"
      end

    label =
      if row["provisional"] == true or row["authority"] == "provisional",
        do: label <> "; pending local memory",
        else: label

    "- [#{label}; #{id}; revision #{revision || "None"}] #{String.trim(row["content"] || "")}"
  end
end
