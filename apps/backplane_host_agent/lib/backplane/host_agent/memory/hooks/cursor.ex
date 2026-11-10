defmodule Backplane.HostAgent.Memory.Hooks.Cursor do
  @moduledoc """
  Normalizes Cursor hook input (camelCase hook names, `conversation_id`,
  `workspace_roots`) into canonical capture envelopes.

  Cursor's text fields use different names than the gateway projector reads, so
  `text`, `output`/`tool_output` are also copied into `message`/`tool_response`
  inside the payload source map when those conventional keys are absent.
  """

  alias Backplane.HostAgent.Memory.EventEnvelope

  @hooks %{
    "sessionstart" => {"session-start", "agent.session.started"},
    "beforesubmitprompt" => {"before-submit-prompt", "agent.prompt.submitted"},
    "posttooluse" => {"post-tool-use", "agent.tool.completed"},
    "aftershellexecution" => {"after-shell-execution", "agent.tool.completed"},
    "afterfileedit" => {"after-file-edit", "agent.tool.completed"},
    "afteragentresponse" => {"after-agent-response", "conversation.agent_message"},
    "stop" => {"stop", "agent.session.stopped"},
    "sessionend" => {"session-end", "agent.session.ended"}
  }

  @supported_hooks ~w(
    sessionStart beforeSubmitPrompt postToolUse afterShellExecution afterFileEdit
    afterAgentResponse stop sessionEnd
  )

  @doc "Lists the Cursor hook names captured by this adapter."
  def supported_hooks, do: @supported_hooks

  @doc "Normalizes one supported Cursor hook using trusted host configuration."
  @spec normalize(String.t(), map(), map() | struct()) ::
          {:ok, map()} | {:error, :unsupported_hook | {:malformed, [atom()]}}
  def normalize(hook, source, config) when is_binary(hook) and is_map(source) do
    with {:ok, canonical_hook, event_type} <- resolve_hook(hook),
         {:ok, conversation_id} <- required_string(source, "conversation_id"),
         {:ok, host_id} <- required_config_string(config, :host_id),
         {:ok, occurred_at} <- occurred_at(source) do
      payload = %{
        "hook" => canonical_hook,
        "source" => source_payload(canonical_hook, source),
        "repository_sources" => Backplane.HostAgent.Memory.GitContext.discover(project(source))
      }

      idempotency_key =
        "cursor:#{conversation_id}:#{canonical_hook}:#{digest(source_id(canonical_hook, source))}"

      envelope = %{
        schema_version: 1,
        event_id: deterministic_uuid(idempotency_key),
        host_id: host_id,
        agent_id: agent_id(source, config),
        client_id: "cursor",
        integration: "cursor",
        project: project(source),
        scope: scope(source),
        session_id: conversation_id,
        event_type: event_type,
        occurred_at: occurred_at,
        captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
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

      {:ok, Map.reject(envelope, fn {_key, value} -> is_nil(value) end)}
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

  # Tool hooks fire many times per generation, so the generation id alone would
  # collapse distinct tool calls; fold the full input digest in for them.
  defp source_id(hook, source)
       when hook in ["post-tool-use", "after-shell-execution", "after-file-edit"],
       do:
         (optional_string(source, "generation_id") || "") <> ":" <> digest(Jason.encode!(source))

  defp source_id(_hook, source),
    do: optional_string(source, "generation_id") || digest(Jason.encode!(source))

  defp source_payload(hook, source) do
    source
    |> Map.drop(["host_id", :host_id, "user_email", :user_email])
    |> put_missing("message", hook == "after-agent-response" && Map.get(source, "text"))
    |> put_missing("tool_response", Map.get(source, "tool_output") || Map.get(source, "output"))
    |> put_missing("tool_name", tool_name(hook, source))
  end

  defp tool_name("after-shell-execution", _source), do: "Shell"
  defp tool_name("after-file-edit", _source), do: "Edit"
  defp tool_name(_hook, _source), do: nil

  defp put_missing(map, key, value) when is_binary(value) and value != "",
    do: Map.put_new(map, key, value)

  defp put_missing(map, _key, _value), do: map

  defp agent_id(source, config) do
    optional_config_string(config, :agent_id) || optional_string(source, "agent_id") || "cursor"
  end

  defp project(source) do
    case Map.get(source, "workspace_roots") do
      [root | _] when is_binary(root) and root != "" -> root
      _ -> optional_string(source, "cwd") || optional_string(source, "project")
    end
  end

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

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

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
end
