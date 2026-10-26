defmodule Backplane.OpenClawCaptureContract do
  @moduledoc "Pure, versioned OpenClaw evidence validation shared by host and canonical ingestion."

  alias Backplane.MemorySourceContract, as: Source

  @protocol "openclaw_capture.v1"
  @common ~w(protocol event_id installation_id profile_id source_sequence session_id parent_session_id occurred_at captured_at agent_id cwd repository_sources run_id session_key occurrence_id input_provenance binding_fingerprint)
  @message ~w(source_revision role content completeness message_uid source_reference tool_call_uid tool_call_uids absorbed_message_uids tool_call_id author message_index)
  @reserved ~w(host_id client_id source_client_id memory_space_id scope namespace partition requesting_actor authority_version access_id memory_access_id)
  @roles %{
    "user" => "conversation.user_message",
    "assistant" => "conversation.agent_message",
    "tool" => "agent.tool.completed"
  }
  @hooks %{"session-start" => "agent.session.started", "session-end" => "agent.session.ended"}
  @max_safe_integer 9_007_199_254_740_991

  def protocol, do: @protocol
  def hooks, do: ["session-start", "message", "session-end"]

  def validate(hook, source, opts \\ [])

  def validate(hook, source, opts) when is_map(source) do
    with {:ok, event_type} <- event_type(hook, source),
         true <- valid_common?(source),
         true <- valid_hook?(hook, source, opts),
         true <- not reserved?(source),
         true <- safe_integers?(source),
         {:ok, encoded} <- Source.encode(source),
         true <- byte_size(encoded) <= Source.limits().page_bytes do
      {:ok, event_type}
    else
      {:error, :unsupported_hook} = error -> error
      _ -> {:error, :invalid_capture}
    end
  end

  def validate(_, _, _), do: {:error, :invalid_capture}

  defp event_type("message", %{"role" => role}) when is_map_key(@roles, role),
    do: {:ok, Map.fetch!(@roles, role)}

  defp event_type(hook, _) when is_map_key(@hooks, hook), do: {:ok, Map.fetch!(@hooks, hook)}
  defp event_type("message", _), do: {:error, :invalid_capture}
  defp event_type(_, _), do: {:error, :unsupported_hook}

  defp valid_common?(source) do
    source["protocol"] == @protocol and Source.uuid?(source["event_id"]) and
      Source.uuid?(source["installation_id"]) and text?(source["profile_id"], 512) and
      text?(source["session_id"], 4096) and text?(source["agent_id"], 512) and
      positive?(source["source_sequence"]) and hash?(source["binding_fingerprint"]) and
      timestamp?(source["occurred_at"]) and timestamp?(source["captured_at"]) and
      Enum.all?(~w(parent_session_id cwd run_id session_key occurrence_id), fn key ->
        not Map.has_key?(source, key) or text?(source[key], 4096)
      end) and
      (not Map.has_key?(source, "input_provenance") or is_map(source["input_provenance"])) and
      (not Map.has_key?(source, "repository_sources") or
         (is_list(source["repository_sources"]) and length(source["repository_sources"]) <= 32 and
            Enum.all?(source["repository_sources"], &is_map/1)))
  end

  defp valid_hook?("message", source, opts) do
    Map.keys(source) -- (@common ++ @message) == [] and
      text?(source["content"], Source.limits().content_bytes) and
      text?(source["occurrence_id"], 4096) and valid_completeness?(source, opts) and
      (not Map.has_key?(source, "source_revision") or positive?(source["source_revision"])) and
      (not Map.has_key?(source, "message_index") or
         (is_integer(source["message_index"]) and source["message_index"] >= 0)) and
      (not Map.has_key?(source, "author") or is_map(source["author"])) and
      Enum.all?(~w(message_uid source_reference tool_call_uid tool_call_id), fn key ->
        not Map.has_key?(source, key) or text?(source[key], 4096)
      end) and
      Enum.all?(~w(tool_call_uids absorbed_message_uids), fn key ->
        not Map.has_key?(source, key) or
          (is_list(source[key]) and length(source[key]) <= 256 and
             Enum.all?(source[key], &text?(&1, 4096)))
      end)
  end

  defp valid_hook?(_, source, _opts),
    do:
      Map.keys(source) -- (@common ++ ["lifecycle"]) == [] and
        (not Map.has_key?(source, "lifecycle") or is_map(source["lifecycle"]))

  # No partial archive contract is advertised. Missing or excerpted input is rejected,
  # never silently persisted as a complete authoritative message.
  defp valid_completeness?(%{"completeness" => completeness, "content" => content}, opts)
       when is_map(completeness) and is_binary(content) do
    digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    length = length(String.codepoints(content))

    original =
      completeness["coverage"] == "full" and completeness["original_length"] == length and
        completeness["original_sha256"] == digest

    redacted =
      opts[:filtered] == true and completeness["coverage"] == "redacted" and
        completeness["retained_length"] == length and completeness["retained_sha256"] == digest and
        is_integer(completeness["original_length"]) and completeness["original_length"] >= 0 and
        hash?(completeness["original_sha256"])

    Map.keys(completeness) --
      ~w(truncated original_length original_sha256 coverage retained_length retained_sha256) == [] and
      completeness["truncated"] == false and (original or redacted)
  end

  defp valid_completeness?(_, _), do: false

  defp positive?(value), do: is_integer(value) and value in 1..@max_safe_integer
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp timestamp?(value),
    do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp reserved?(value) when is_map(value),
    do: Enum.any?(value, fn {key, item} -> key in @reserved or reserved?(item) end)

  defp reserved?(value) when is_list(value), do: Enum.any?(value, &reserved?/1)
  defp reserved?(_), do: false
  defp safe_integers?(value) when is_integer(value), do: abs(value) <= @max_safe_integer

  defp safe_integers?(value) when is_map(value),
    do: Enum.all?(value, fn {_, item} -> safe_integers?(item) end)

  defp safe_integers?(value) when is_list(value), do: Enum.all?(value, &safe_integers?/1)
  defp safe_integers?(_), do: true
end
