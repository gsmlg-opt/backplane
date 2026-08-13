defmodule Backplane.HostAgent.Memory.Hooks.ClaudeCode do
  @moduledoc "Normalizes Claude Code lifecycle hooks into canonical capture envelopes."

  alias Backplane.HostAgent.Memory.EventEnvelope

  @hooks %{
    "sessionstart" => {"session-start", "agent.session.started"},
    "userpromptsubmit" => {"user-prompt-submit", "agent.prompt.submitted"},
    "posttooluse" => {"post-tool-use", "agent.tool.completed"},
    "posttoolusefailure" => {"post-tool-use-failure", "agent.tool.failed"},
    "precompact" => {"pre-compact", "agent.context.pre_compact"},
    "subagentstart" => {"subagent-start", "agent.subagent.started"},
    "subagentstop" => {"subagent-stop", "agent.subagent.stopped"},
    "stop" => {"stop", "agent.session.stopped"},
    "sessionend" => {"session-end", "agent.session.ended"},
    "postcommit" => {"post-commit", "git.commit.created"}
  }

  @doc "Normalizes one supported Claude Code hook using trusted host configuration."
  @spec normalize(String.t(), map(), map() | struct()) ::
          {:ok, map()} | {:error, :unsupported_hook | {:malformed, [atom()]}}
  def normalize(hook, source, config) when is_binary(hook) and is_map(source) do
    with {:ok, canonical_hook, event_type} <- resolve_hook(hook),
         {:ok, session_id} <- required_string(source, "session_id"),
         {:ok, host_id} <- required_config_string(config, :host_id),
         {:ok, occurred_at} <- occurred_at(source) do
      payload = %{
        "hook" => canonical_hook,
        "source" => Map.drop(source, ["host_id", :host_id])
      }

      source_id = source_id(source)
      idempotency_key = "claude_code:#{session_id}:#{canonical_hook}:#{digest(source_id)}"
      captured_at = DateTime.utc_now() |> DateTime.to_iso8601()

      envelope = %{
        schema_version: 1,
        event_id: deterministic_uuid(idempotency_key),
        host_id: host_id,
        agent_id: agent_id(source, config),
        client_id: "claude_code",
        integration: "claude_code",
        project: project(source),
        scope: scope(source),
        session_id: session_id,
        parent_session_id: optional_string(source, "parent_session_id"),
        event_type: event_type,
        occurred_at: occurred_at,
        captured_at: captured_at,
        idempotency_key: idempotency_key,
        payload_hash: EventEnvelope.payload_hash(payload),
        privacy: %{
          "filtered" => false,
          "filter_version" => "pending",
          "redaction_count" => 0,
          "private_blocks_removed" => 0
        },
        trace: trace(source),
        payload: payload
      }

      {:ok, drop_nil_values(envelope)}
    end
  end

  def normalize(hook, _source, _config) when not is_binary(hook),
    do: {:error, :unsupported_hook}

  def normalize(_hook, _source, _config), do: {:error, {:malformed, [:payload]}}

  defp resolve_hook(hook) do
    key = hook |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    case Map.fetch(@hooks, key) do
      {:ok, {canonical, event_type}} -> {:ok, canonical, event_type}
      :error -> {:error, :unsupported_hook}
    end
  end

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, {:malformed, [String.to_atom(key)]}}
      value -> {:ok, value}
    end
  end

  defp required_config_string(config, key) do
    case value(config, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:malformed, [key]}}, else: {:ok, value}

      _ ->
        {:error, {:malformed, [key]}}
    end
  end

  defp occurred_at(source) do
    case value(source, :occurred_at) || value(source, :timestamp) do
      nil ->
        {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}

      timestamp when is_binary(timestamp) ->
        if match?({:ok, _, _}, DateTime.from_iso8601(timestamp)),
          do: {:ok, timestamp},
          else: {:error, {:malformed, [:occurred_at]}}

      _ ->
        {:error, {:malformed, [:occurred_at]}}
    end
  end

  defp source_id(source) do
    Enum.find_value(~w(source_event_id hook_event_id tool_use_id), fn key ->
      optional_string(source, key)
    end) || unique_capture_id()
  end

  defp unique_capture_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp agent_id(source, config) do
    optional_config_string(config, :agent_id) || optional_string(source, "agent_id") ||
      "claude_code"
  end

  defp project(source), do: optional_string(source, "cwd") || optional_string(source, "project")

  defp scope(source) do
    optional_string(source, "scope") ||
      case project(source) do
        nil -> nil
        project -> "project:" <> project
      end
  end

  defp trace(source) do
    case value(source, :trace) do
      trace when is_map(trace) -> trace
      _ -> %{}
    end
  end

  defp optional_config_string(config, key) do
    case value(config, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _ -> nil
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _ -> nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_config, _key), do: nil

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp deterministic_uuid(value) do
    <<prefix::binary-size(6), _version::4, version_tail::12, _variant::2, variant_tail::62,
      _rest::binary>> = :crypto.hash(:sha256, value)

    <<prefix::binary, 5::4, version_tail::12, 2::2, variant_tail::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
                 e::binary-size(12)>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
