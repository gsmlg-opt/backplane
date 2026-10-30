defmodule Backplane.OpenClawCaptureBarrier do
  @moduledoc false

  # A public chat terminal is separate from plugin agent_end and canonical capture ACKs.
  # These are observations of the real journal; none of them performs delivery work.
  def settled?(snapshot, turns) do
    expected = MapSet.new(turns, &identity/1)
    journal = snapshot["journal"] || %{}

    completed =
      for row <- journal["turns"] || [],
          row["completed"] == 1,
          encoded when is_binary(encoded) <- [row["identity"]],
          {:ok, id} <- [Jason.decode(encoded)],
          MapSet.member?(expected, id),
          into: MapSet.new(),
          do: id

    captures =
      Enum.filter(journal["deliveries"] || [], fn row ->
        String.starts_with?(row["path"] || "", "/capture/v1/hooks/openclaw/") and
          MapSet.member?(expected, payload_identity(row["payload"] || %{}))
      end)

    admitted =
      captures
      |> Enum.filter(&(get_in(&1, ["payload", "role"]) == "user"))
      |> MapSet.new(&payload_identity(&1["payload"]))

    MapSet.size(expected) == length(turns) and length(turns) > 0 and
      completed == expected and admitted == expected and Enum.all?(captures, &committed?/1)
  end

  defp identity(turn), do: [turn["agentId"], turn["sessionId"], turn["runId"]]

  defp payload_identity(payload),
    do: [payload["agent_id"], payload["session_id"], payload["run_id"]]

  defp committed?(%{"state" => "canonical_committed", "event_id" => id, "receipt" => receipt})
       when is_binary(id) and id != "" and is_map(receipt),
       do: receipt["event_id"] == id and receipt["status"] == "committed"

  defp committed?(_), do: false
end
