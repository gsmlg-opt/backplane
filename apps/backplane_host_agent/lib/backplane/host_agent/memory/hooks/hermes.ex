defmodule Backplane.HostAgent.Memory.Hooks.Hermes do
  @moduledoc "Normalizes the versioned Hermes provider journal into the existing capture pipeline."
  alias Backplane.HostAgent.Memory.EventEnvelope
  alias Backplane.MemorySourceContract, as: Contract

  @hooks %{
    "session-start" => "agent.session.started",
    "session-end" => "agent.session.ended",
    "pre-compress" => "agent.context.pre_compact"
  }
  @roles %{
    "user" => "conversation.user_message",
    "assistant" => "conversation.agent_message",
    "tool" => "agent.tool.completed"
  }
  @common ~w(protocol event_id installation_id profile_id source_sequence session_id parent_session_id occurred_at captured_at agent_id cwd repository_sources)
  @message ~w(source_revision role content completeness message_uid source_reference tool_call_uid tool_call_uids absorbed_message_uids tool_call_id author)
  @reserved ~w(host_id client_id source_client_id memory_space_id scope namespace partition requesting_actor authority_version access_id memory_access_id)

  def supported_hooks, do: Map.keys(@hooks) ++ ["message"]

  def normalize(hook, source, runtime) when is_map(source) and is_map(runtime) do
    with {:ok, event_type} <- event_type(hook, source),
         true <- valid_common?(source, runtime),
         true <- valid_hook?(hook, source),
         true <- not reserved?(source),
         true <- EventEnvelope.valid_payload?(source),
         true <- byte_size(Jason.encode!(source)) <= 480_000 do
      payload = %{
        "hook" => hook,
        "source" => source,
        "repository_sources" => Map.get(source, "repository_sources", [])
      }

      envelope = %{
        schema_version: 1,
        event_id: source["event_id"],
        host_id: runtime.host_id,
        agent_id: source["agent_id"] || runtime[:agent_id] || "hermes",
        client_id: "hermes",
        integration: "hermes",
        session_id: source["session_id"],
        parent_session_id: source["parent_session_id"],
        project: source["cwd"],
        event_type: event_type,
        occurred_at: source["occurred_at"],
        captured_at: source["captured_at"],
        idempotency_key:
          "hermes:" <>
            source["installation_id"] <> ":" <> source["profile_id"] <> ":" <> source["event_id"],
        payload_hash: EventEnvelope.payload_hash(payload),
        privacy: %{
          "filtered" => false,
          "filter_version" => "pending",
          "redaction_count" => 0,
          "private_blocks_removed" => 0
        },
        trace: %{},
        payload: payload
      }

      {:ok, Map.reject(envelope, fn {_key, value} -> is_nil(value) end)}
    else
      {:error, :unsupported_hook} = error -> error
      _ -> {:error, {:malformed, [:payload]}}
    end
  end

  def normalize(_, _, _), do: {:error, {:malformed, [:payload]}}

  defp event_type("message", source), do: {:ok, @roles[source["role"]]}

  defp event_type(hook, _source) do
    case Map.fetch(@hooks, hook) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :unsupported_hook}
    end
  end

  defp valid_common?(source, runtime) do
    source["protocol"] == "hermes_capture.v1" and Contract.uuid?(source["event_id"]) and
      Contract.uuid?(source["installation_id"]) and text?(source["profile_id"], 512) and
      text?(source["session_id"], 4096) and text?(runtime[:host_id], 512) and
      is_integer(source["source_sequence"]) and
      source["source_sequence"] in 1..9_223_372_036_854_775_807 and
      timestamp?(source["occurred_at"]) and timestamp?(source["captured_at"]) and
      Enum.all?(
        ~w(parent_session_id cwd agent_id),
        &(not Map.has_key?(source, &1) or
            text?(source[&1], if(&1 == "agent_id", do: 512, else: 4096)))
      ) and
      (not Map.has_key?(source, "repository_sources") or
         (is_list(source["repository_sources"]) and length(source["repository_sources"]) <= 32 and
            Enum.all?(source["repository_sources"], &is_map/1)))
  end

  defp valid_hook?("message", source) do
    Map.keys(source) -- (@common ++ @message) == [] and source["role"] in Map.keys(@roles) and
      text?(source["content"], 262_144) and
      (not Map.has_key?(source, "source_revision") or
         (is_integer(source["source_revision"]) and source["source_revision"] > 0)) and
      (not Map.has_key?(source, "author") or is_map(source["author"])) and
      valid_completeness?(source)
  end

  defp valid_hook?(_, source),
    do:
      Map.keys(source) -- (@common ++ ["lifecycle"]) == [] and
        (not Map.has_key?(source, "lifecycle") or is_map(source["lifecycle"]))

  defp valid_completeness?(%{"completeness" => completeness} = source)
       when is_map(completeness) do
    completeness["truncated"] in [true, false] and is_integer(completeness["original_length"]) and
      completeness["original_length"] >= 0 and text?(completeness["coverage"], 128) and
      is_binary(completeness["original_sha256"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, completeness["original_sha256"]) and
      (not completeness["truncated"] or
         (text?(source["source_reference"], 4096) and
            completeness["original_length"] > String.length(source["content"])))
  end

  defp valid_completeness?(source), do: not Map.has_key?(source, "completeness")

  defp reserved?(map) when is_map(map),
    do: Enum.any?(map, fn {key, value} -> key in @reserved or reserved?(value) end)

  defp reserved?(list) when is_list(list), do: Enum.any?(list, &reserved?/1)
  defp reserved?(_), do: false

  defp timestamp?(value),
    do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp text?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit and
        String.trim(value) != "" and not String.contains?(value, <<0>>)
end
