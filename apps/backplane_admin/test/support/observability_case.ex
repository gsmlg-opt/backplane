defmodule Backplane.Admin.ObservabilityCase do
  @moduledoc false

  alias Backplane.LLM.ProxyRequest, as: LlmProxyRequest
  alias Backplane.MCP.{ProxyRequest, ToolCall}
  alias Backplane.Repo

  def insert_llm_log(attrs \\ %{}) do
    defaults = %{
      event_id: "llm-event-#{System.unique_integer()}",
      operation: "chat.completions",
      outcome: "success",
      requested_model: "test-model",
      status: 200,
      duration_ms: 120,
      input_tokens: 10,
      output_tokens: 5,
      request_id: "req-#{System.unique_integer()}",
      trace_id: "trace-#{System.unique_integer()}",
      metadata: %{"surface" => "openai"}
    }

    insert_record(LlmProxyRequest, defaults, attrs)
  end

  def insert_mcp_log(attrs \\ %{}) do
    defaults = %{
      event_id: "mcp-event-#{System.unique_integer()}",
      operation: "jsonrpc",
      rpc_method: "tools/call",
      outcome: "success",
      request_id: "mcp-req-#{System.unique_integer()}",
      trace_id: "mcp-trace-#{System.unique_integer()}",
      auth_kind: "open",
      protocol_version: "2024-11-05",
      transport: "streamable-http",
      session_id: "sess-123",
      duration_ms: 45,
      metadata: %{"client" => "test"}
    }

    insert_record(ProxyRequest, defaults, attrs)
  end

  def insert_mcp_tool_call(attrs \\ %{}) do
    defaults = %{
      event_id: "tool-event-#{System.unique_integer()}",
      tool_name: "math::add",
      outcome: "success",
      mcp_request_id: "mcp-req-link",
      trace_id: "mcp-trace-link",
      upstream_name: "managed-math",
      arguments_hash: "abc123",
      duration_ms: 12,
      metadata: %{}
    }

    insert_record(ToolCall, defaults, attrs)
  end

  def clear_observability_logs! do
    Repo.delete_all(ToolCall)
    Repo.delete_all(ProxyRequest)
    Repo.delete_all(LlmProxyRequest)
  end

  defp insert_record(schema_module, defaults, attrs) do
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)
    inserted_at = inserted_at || DateTime.utc_now()

    defaults
    |> Map.merge(attrs)
    |> then(&schema_module.insert_changeset/1)
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Repo.insert!()
  end
end
