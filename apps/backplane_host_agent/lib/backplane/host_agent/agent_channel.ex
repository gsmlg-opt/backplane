defmodule Backplane.HostAgent.AgentChannel do
  @moduledoc """
  Host-agent Phoenix channel client callbacks.
  """

  use Phoenix.SocketClient.Channel

  alias Backplane.HostAgent.{ApiForwarder, Services}
  alias Backplane.HostAgent.Memory.Edge.Syncer
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

  def handle_message("api_services", payload, state) when is_map(payload) do
    with {:ok, forwarder, state} <- api_forwarder(state),
         :ok <- ApiForwarder.configure(forwarder, payload) do
      registrations =
        payload["services"]
        |> Enum.reject(&(&1["enabled"] == false))
        |> Enum.map(&Map.take(&1, ["id", "revision"]))

      Helpers.handle_push_cast(
        {"api_services_registered", %{"protocol" => "host_api.v1", "services" => registrations}},
        state
      )
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_message("api_request", payload, state) when is_map(payload) do
    result =
      with {:ok, forwarder} <- current_api_forwarder(state) do
        ApiForwarder.request(forwarder, payload)
      end

    case result do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Helpers.handle_push_cast(
          {"api_response",
           %{
             "request_id" => payload["request_id"],
             "type" => "error",
             "code" => Atom.to_string(reason)
           }},
          state
        )
    end
  end

  def handle_message("api_cancel", %{"request_id" => id}, state) do
    with {:ok, forwarder} <- current_api_forwarder(state) do
      ApiForwarder.cancel(forwarder, id)
    end

    {:noreply, state}
  end

  def handle_message("memory_access_changed", hint, state) when is_map(hint) do
    syncer_module().memory_access_changed(%{channel: self(), hint: hint})
    {:noreply, state}
  end

  def handle_message("memory_available", hint, state) when is_map(hint) do
    syncer_module().memory_available(hint)
    {:noreply, state}
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

  defp current_api_forwarder(state) do
    case get_in(state.hooks, [:host_api_forwarder]) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :service_unavailable}

      nil ->
        {:error, :service_unavailable}
    end
  end

  defp api_forwarder(state) do
    case current_api_forwarder(state) do
      {:ok, pid} ->
        {:ok, pid, state}

      {:error, :service_unavailable} ->
        with {:ok, pid} <- ApiForwarder.start(self()) do
          {:ok, pid, put_in(state.hooks[:host_api_forwarder], pid)}
        end
    end
  end

  defp syncer_module,
    do: Application.get_env(:backplane_host_agent, :edge_syncer_module, Syncer)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
