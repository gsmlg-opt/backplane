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
