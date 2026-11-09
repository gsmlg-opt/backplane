defmodule Backplane.HostAgent.HubProxy do
  @moduledoc """
  Proxies local MCP requests to the Backplane hub over the host-agent channel.
  """

  alias Backplane.HostAgent.{Channel, MemoryProxy, Trace}

  @tool_call_timeout 30_000

  @spec list_tools() :: {:ok, [map()]} | {:error, term()}
  def list_tools do
    push("mcp_tools_list", %{})
    |> normalize_tools_list()
  end

  @spec call_tool(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(name, args) when is_binary(name) and is_map(args) do
    push("mcp_tool_call", trace_payload(%{"name" => name, "arguments" => args}))
    |> normalize_tool_call()
  end

  @doc "Pulls this host's gateway records changed after `cursor`."
  @spec pull_memory(map() | nil, pos_integer()) ::
          {:ok, %{String.t() => list() | map() | nil}} | {:error, term()}
  def pull_memory(cursor, limit) when (is_map(cursor) or is_nil(cursor)) and is_integer(limit) do
    push("memory_pull", %{"cursor" => cursor, "limit" => limit})
    |> normalize_pull()
  end

  defp push(event, payload) do
    with channel when is_pid(channel) <- MemoryProxy.channel(),
         true <- Process.alive?(channel) do
      try do
        channel_module().push(channel, event, payload, @tool_call_timeout)
      catch
        :exit, reason -> {:error, push_exit_reason(reason)}
      end
    else
      _ -> {:error, :not_connected}
    end
  end

  defp normalize_tools_list({:ok, %{"ok" => true, "result" => %{"tools" => tools}}})
       when is_list(tools) do
    {:ok, tools}
  end

  defp normalize_tools_list({:ok, %{"ok" => true, "result" => tools}}) when is_list(tools) do
    {:ok, tools}
  end

  defp normalize_tools_list({:ok, %{"ok" => false, "error" => error}}), do: {:error, error}
  defp normalize_tools_list({:ok, %{"error" => error}}), do: {:error, error}
  defp normalize_tools_list({:error, reason}), do: {:error, reason}
  defp normalize_tools_list(other), do: {:error, {:unexpected_reply, other}}

  defp normalize_tool_call({:ok, %{"ok" => true, "result" => result}}), do: {:ok, result}
  defp normalize_tool_call({:ok, %{"ok" => false, "error" => error}}), do: {:error, error}
  defp normalize_tool_call({:ok, %{"error" => error}}), do: {:error, error}
  defp normalize_tool_call({:error, reason}), do: {:error, reason}
  defp normalize_tool_call(other), do: {:error, {:unexpected_reply, other}}

  defp normalize_pull({:ok, %{"records" => records} = reply}) when is_list(records),
    do: {:ok, %{"records" => records, "cursor" => Map.get(reply, "cursor")}}

  defp normalize_pull({:error, %{"code" => code}}) when is_binary(code), do: {:error, code}
  defp normalize_pull({:error, reason}), do: {:error, reason}
  defp normalize_pull(other), do: {:error, {:unexpected_reply, other}}

  defp push_exit_reason({reason, _stack}), do: reason
  defp push_exit_reason(reason), do: reason

  defp channel_module do
    Application.get_env(:backplane_host_agent, :channel_module, Channel)
  end

  defp trace_payload(payload) do
    case Trace.child_ctx(Trace.current()) do
      nil -> payload
      ctx -> Map.put(payload, "traceparent", Trace.to_traceparent(ctx))
    end
  end
end
