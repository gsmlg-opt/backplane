defmodule Backplane.HostAgent.AgentChannel do
  @moduledoc """
  Host-agent Phoenix channel client callbacks.
  """

  use Phoenix.SocketClient.Channel

  alias Backplane.HostAgent.Services
  alias Phoenix.SocketClient.Channel.Helpers

  @impl true
  def handle_message("plugin_call", payload, state) when is_map(payload) do
    Helpers.handle_push_cast(
      {"plugin_call_result", plugin_call_result(payload, %{channel: self()})},
      state
    )
  end

  def handle_message(_event, _payload, state), do: {:noreply, state}

  def plugin_call_result(payload), do: plugin_call_result(payload, %{})

  def plugin_call_result(%{"call_id" => call_id, "name" => name, "arguments" => args}, ctx)
      when is_binary(call_id) and is_binary(name) and is_map(args) do
    case Services.resolve(name) do
      {:ok, service, bare} ->
        case service.call(bare, args, ctx) do
          {:ok, result} -> %{"call_id" => call_id, "ok" => true, "result" => result}
          {:error, reason} -> plugin_call_error(call_id, reason)
        end

      :error ->
        plugin_call_error(call_id, {:unknown_tool, name})
    end
  end

  def plugin_call_result(payload, _ctx) when is_map(payload) do
    plugin_call_error(payload["call_id"], "invalid plugin call")
  end

  defp plugin_call_error(call_id, reason) do
    %{"call_id" => call_id, "ok" => false, "error" => format_error(reason)}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
