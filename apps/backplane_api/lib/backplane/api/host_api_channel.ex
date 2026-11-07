defmodule Backplane.Api.HostApiChannel do
  @moduledoc false

  import Phoenix.Channel, only: [push: 3, reply: 2, socket_ref: 1]
  import Phoenix.Socket, only: [assign: 3]

  alias Backplane.HostApi.Transport
  alias Backplane.LLM.HostServices

  def join(socket, %{"host_api" => %{"protocol" => "host_api.v1"}}) do
    host = socket.assigns.host.id
    :ok = Transport.connect(host, self())
    Phoenix.PubSub.subscribe(Backplane.PubSub, "host_api_services:#{host}")
    send(self(), :host_api_services)
    assign(socket, :host_api, true)
  end

  def join(socket, _payload), do: assign(socket, :host_api, false)

  def registered(socket, %{"protocol" => "host_api.v1", "services" => services}, true)
      when is_list(services) and length(services) <= 64 do
    with true <- socket.assigns.host_api,
         {:ok, ready} <- registration(services),
         expected =
           Map.new(HostServices.snapshot(socket.assigns.host.id), &{&1["id"], &1["revision"]}),
         true <- ready == expected,
         :ok <- Transport.ready(socket.assigns.host.id, self(), ready) do
      {:reply, {:ok, %{"ok" => true}}, socket}
    else
      _ -> {:reply, {:error, %{"code" => "service_unavailable"}}, socket}
    end
  end

  def registered(socket, _payload, _active), do: unauthorized(socket)

  def response(socket, payload, true) when is_map(payload) do
    if socket.assigns.host_api do
      case Transport.deliver(socket.assigns.host.id, self(), payload, socket_ref(socket)) do
        :ok ->
          {:noreply, socket}

        {:error, _} ->
          Transport.fail(socket.assigns.host.id, self(), payload["request_id"], :invalid_response)
          {:reply, {:error, %{"code" => "invalid_response"}}, socket}
      end
    else
      unauthorized(socket)
    end
  end

  def response(socket, _payload, _active), do: unauthorized(socket)

  def inventory(socket, true) do
    if socket.assigns.host_api do
      host = socket.assigns.host.id
      :ok = Transport.invalidate(host, self())

      push(socket, "api_services", %{
        "protocol" => "host_api.v1",
        "services" => HostServices.snapshot(host)
      })
    end

    {:noreply, socket}
  end

  def inventory(socket, false), do: retire(socket)

  def request(socket, id, payload, true) do
    host = socket.assigns.host.id

    with true <- socket.assigns.host_api,
         {:ok, service, _url} <- HostServices.endpoint(payload["service_id"], payload["api"]),
         true <- service.host_id == host and service.revision == payload["service_revision"] do
      push(socket, "api_request", payload)
      {:noreply, socket}
    else
      _ ->
        Transport.fail(host, self(), id, :service_unavailable)
        {:noreply, socket}
    end
  end

  def request(socket, _id, _payload, false), do: retire(socket)

  def ack(socket, reference, :ok, true) do
    reply(reference, {:ok, %{"ok" => true}})
    {:noreply, socket}
  end

  def ack(socket, reference, _result, _active) do
    reply(reference, {:error, %{"code" => "cancelled"}})
    {:noreply, socket}
  end

  def cancel(socket, id) do
    if socket.assigns.host_api, do: push(socket, "api_cancel", %{"request_id" => id})
    {:noreply, socket}
  end

  defp registration(services) do
    Enum.reduce_while(services, {:ok, %{}}, fn
      %{"id" => id, "revision" => revision}, {:ok, acc}
      when is_binary(id) and is_integer(revision) and revision > 0 ->
        if Map.has_key?(acc, id),
          do: {:halt, :error},
          else: {:cont, {:ok, Map.put(acc, id, revision)}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp unauthorized(socket) do
    Transport.disconnect(socket.assigns.host.id, self())
    {:reply, {:error, %{"code" => "unauthorized"}}, socket}
  end

  defp retire(socket) do
    Transport.disconnect(socket.assigns.host.id, self())
    {:noreply, socket}
  end
end
