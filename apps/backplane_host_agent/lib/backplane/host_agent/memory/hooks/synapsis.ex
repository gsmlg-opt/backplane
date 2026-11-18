defmodule Backplane.HostAgent.Memory.Hooks.Synapsis do
  @moduledoc """
  Normalizes the Synapsis lifecycle hook contract, schema version `1.0`.

  The caller supplies one stable event UUID per logical hook, a durable session
  UUID, the trusted project root in `cwd`, a UTC ISO 8601 `timestamp`, and a
  hook-specific `payload`. Optional `agent_id` records the configured agent.
  Host provenance comes from the local capture runtime.
  """

  alias Backplane.HostAgent.Memory.EventEnvelope

  @hooks %{
    "session-start" => "agent.session.started",
    "user-prompt-submit" => "agent.prompt.submitted",
    "post-tool-use" => "agent.tool.completed",
    "session-end" => "agent.session.ended"
  }
  @common ~w(schema_version event_id session_id cwd timestamp agent_id payload)

  @doc "Returns the four hooks in the Synapsis 1.0 contract."
  def supported_hooks, do: Map.keys(@hooks)

  @doc "Normalizes a public lifecycle payload for durable host capture."
  def normalize(hook, source, runtime) when is_map(source) and is_map(runtime) do
    with {:ok, event_type} <- Map.fetch(@hooks, hook),
         true <- valid_common?(source, runtime),
         true <- valid_hook?(hook, source["payload"]),
         true <- EventEnvelope.valid_payload?(source),
         true <- bounded_json?(source) do
      payload = %{"hook" => hook, "source" => source}

      {:ok,
       %{
         schema_version: 1,
         event_id: source["event_id"],
         host_id: runtime.host_id,
         agent_id: runtime[:agent_id] || source["agent_id"] || "synapsis",
         client_id: "synapsis",
         integration: "synapsis",
         project: source["cwd"],
         session_id: source["session_id"],
         event_type: event_type,
         occurred_at: source["timestamp"],
         idempotency_key:
           Enum.join(["synapsis", source["session_id"], hook, logical_id(hook, source)], ":"),
         payload_hash: EventEnvelope.payload_hash(payload),
         privacy: %{
           "filtered" => false,
           "filter_version" => "pending",
           "redaction_count" => 0,
           "private_blocks_removed" => 0
         },
         trace: %{},
         payload: payload
       }}
    else
      :error -> {:error, :unsupported_hook}
      _ -> {:error, {:malformed, [:payload]}}
    end
  end

  def normalize(_, _, _), do: {:error, {:malformed, [:payload]}}

  defp valid_common?(source, runtime) do
    Map.keys(source) -- @common == [] and source["schema_version"] == "1.0" and
      uuid?(source["event_id"]) and uuid?(source["session_id"]) and
      text?(source["cwd"], 4096) and Path.type(source["cwd"]) == :absolute and
      timestamp?(source["timestamp"]) and text?(runtime[:host_id], 512) and
      (is_nil(runtime[:agent_id]) or text?(runtime[:agent_id], 512)) and
      (not Map.has_key?(source, "agent_id") or text?(source["agent_id"], 512))
  end

  defp valid_hook?("session-start", payload), do: payload == %{}

  defp valid_hook?("user-prompt-submit", payload) when is_map(payload) do
    Map.keys(payload) -- ~w(message_id content) == [] and
      text?(payload["message_id"], 4096) and text?(payload["content"], 262_144)
  end

  defp valid_hook?("post-tool-use", payload) when is_map(payload) do
    Map.keys(payload) -- ~w(tool_call_id tool_name is_error result) == [] and
      text?(payload["tool_call_id"], 4096) and text?(payload["tool_name"], 512) and
      is_boolean(payload["is_error"]) and Map.has_key?(payload, "result")
  end

  defp valid_hook?("session-end", payload) when is_map(payload) do
    Map.keys(payload) == ["reason"] and text?(payload["reason"], 4096)
  end

  defp valid_hook?(_, _), do: false

  defp logical_id("user-prompt-submit", source), do: source["payload"]["message_id"]
  defp logical_id("post-tool-use", source), do: source["payload"]["tool_call_id"]
  defp logical_id(_, source), do: source["event_id"]

  defp bounded_json?(source) do
    case Formata.encode(source, :json) do
      {:ok, json} -> byte_size(json) <= 480_000
      {:error, _} -> false
    end
  end

  defp uuid?(value) do
    is_binary(value) and
      Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value)
  end

  defp timestamp?(value),
    do: is_binary(value) and match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp text?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit and
        String.trim(value) != "" and not String.contains?(value, <<0>>)
end
