defmodule Backplane.HostAgent.AgentChannel do
  @moduledoc """
  Host-agent Phoenix channel client callbacks.
  """

  use Phoenix.SocketClient.Channel

  alias Backplane.HostAgent.Services
  alias Backplane.HostAgent.Memory.{Edge.Syncer, Facts, Store}
  alias Phoenix.SocketClient.Channel.Helpers

  # Rejoining belongs to Worker, which also refreshes capture/command providers
  # and the edge syncer. An unjoined restarted channel is not a live connection.
  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary}
  end

  @impl true
  def handle_message(event, _payload, state) when event in ["phx_error", "phx_close"],
    do: {:stop, :normal, state}

  def handle_message("plugin_call", payload, state) when is_map(payload) do
    Helpers.handle_push_cast(
      {"plugin_call_result", plugin_call_result(payload, %{channel: self()})},
      state
    )
  end

  def handle_message("memory_access_changed", hint, state) when is_map(hint) do
    syncer_module().memory_access_changed(%{channel: self(), hint: hint})
    {:noreply, state}
  end

  def handle_message("memory_available", hint, state) when is_map(hint) do
    syncer_module().memory_available(hint)
    {:noreply, state}
  end

  def handle_message("memory_facts", payload, state) when is_map(payload) do
    case facts_module().apply_facts(payload, store: memory_store(), edge_config: edge_config()) do
      {:ok, _result} ->
        with {:ok, ack} <- receipt_ack(payload) do
          push_cast({"memory_facts_ack", ack}, state)
        else
          _ -> {:noreply, state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_message("memory_wipe", payload, state) when is_map(payload) do
    case facts_module().apply_wipe(payload, store: memory_store()) do
      {:ok, _result} ->
        with {:ok, ack} <- receipt_ack(payload) do
          push_cast({"memory_wipe_ack", ack}, state)
        else
          _ -> {:noreply, state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
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

  defp memory_store,
    do: Application.get_env(:backplane_host_agent, :memory_store, Store)

  defp edge_config,
    do: Application.get_env(:backplane_host_agent, :memory_host_sync_v2, %{})

  defp syncer_module,
    do: Application.get_env(:backplane_host_agent, :edge_syncer_module, Syncer)

  defp facts_module,
    do: Application.get_env(:backplane_host_agent, :memory_facts_module, Facts)

  defp push_cast(message, state) do
    Application.get_env(:backplane_host_agent, :agent_channel_push_module, Helpers)
    |> apply(:handle_push_cast, [message, state])
  end

  defp receipt_ack(%{"receipt_key" => key, "payload_hash" => hash, "scope" => scope})
       when is_binary(key) and is_binary(hash) and is_binary(scope),
       do:
         {:ok,
          %{
            "receipt_key" => key,
            "payload_hash" => hash,
            "scope" => scope,
            "status" => "applied"
          }}

  defp receipt_ack(_payload), do: {:error, :invalid_receipt}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
