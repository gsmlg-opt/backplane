defmodule Backplane.HostAgent.ApiForwarder do
  @moduledoc "Owns declared API services and bounded requests for one channel incarnation."

  use GenServer

  alias Backplane.HostAgent.ApiRequest

  @supervisor Backplane.HostAgent.ApiForwarderSupervisor
  @max_concurrency 8

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start(channel) when is_pid(channel) do
    DynamicSupervisor.start_child(@supervisor, {__MODULE__, channel: channel})
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def configure(pid, payload), do: GenServer.call(pid, {:configure, payload})
  def request(pid, payload), do: GenServer.call(pid, {:request, payload})
  def cancel(pid, id), do: GenServer.call(pid, {:cancel, id})

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)

    task_supervisor =
      case Keyword.fetch(opts, :task_supervisor) do
        {:ok, supervisor} ->
          supervisor

        :error ->
          {:ok, supervisor} = Task.Supervisor.start_link(max_children: @max_concurrency)
          supervisor
      end

    {:ok,
     %{
       channel: channel,
       channel_monitor: Process.monitor(channel),
       task_supervisor: task_supervisor,
       push: Keyword.get(opts, :push, default_push(channel)),
       max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
       services: %{},
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:configure, payload}, _from, state) do
    case normalize_services(payload) do
      {:ok, services} ->
        state = cancel_changed(state, services)
        {:reply, :ok, %{state | services: services}}

      {:error, reason} ->
        state = cancel_changed(state, %{})
        {:reply, {:error, reason}, %{state | services: %{}}}
    end
  end

  def handle_call({:request, payload}, _from, state) do
    with {:ok, request} <- ApiRequest.prepare(payload, state.services),
         :ok <- admission(state, request.request_id) do
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          ApiRequest.run(request, state.push)
        end)

      entry = %{pid: task.pid, ref: task.ref, service_id: request.service_id}
      {:reply, :ok, put_in(state.requests[request.request_id], entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    {:reply, :ok, cancel_request(state, id)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_monitor: ref} = state) do
    {:stop, :normal, cancel_all(state)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, remove_request(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, remove_request(state, ref)}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_all(state)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.take(state, [:channel, :max_concurrency])}
      {:message, _message} -> {:message, :redacted}
      {:reason, _reason} -> {:reason, :redacted}
      {:log, _log} -> {:log, []}
      entry -> entry
    end)
  end

  defp default_push(channel) do
    fn payload ->
      Phoenix.SocketClient.Channel.push(channel, "api_response", payload, 30_000)
    end
  end

  defp admission(state, id) do
    cond do
      Map.has_key?(state.requests, id) -> {:error, :invalid_request}
      map_size(state.requests) >= state.max_concurrency -> {:error, :too_many_requests}
      not Process.alive?(state.channel) -> {:error, :service_unavailable}
      true -> :ok
    end
  end

  defp normalize_services(%{"protocol" => "host_api.v1", "services" => services})
       when is_list(services) and length(services) <= 64 do
    Enum.reduce_while(services, {:ok, %{}}, fn service, {:ok, acc} ->
      case normalize_service(service) do
        {:ok, id, normalized} ->
          if Map.has_key?(acc, id),
            do: {:halt, {:error, :invalid_services}},
            else: {:cont, {:ok, Map.put(acc, id, normalized)}}

        :disabled ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_services(_payload), do: {:error, :invalid_services}

  defp normalize_service(%{"enabled" => false}), do: :disabled

  defp normalize_service(%{"id" => id, "revision" => revision, "endpoints" => endpoints})
       when is_map(endpoints) and is_integer(revision) and revision > 0 do
    valid? =
      ApiRequest.valid_id?(id) and map_size(endpoints) in 1..4 and
        Enum.all?(endpoints, fn {api, url} ->
          api in ApiRequest.apis() and ApiRequest.valid_url?(url)
        end)

    if valid?,
      do: {:ok, id, %{endpoints: endpoints, revision: revision}},
      else: {:error, :invalid_services}
  end

  defp normalize_service(_service), do: {:error, :invalid_services}

  defp cancel_changed(state, services) do
    Enum.reduce(state.requests, state, fn {id, request}, state ->
      if Map.get(state.services, request.service_id) == Map.get(services, request.service_id),
        do: state,
        else: cancel_request(state, id)
    end)
  end

  defp cancel_all(state) do
    Enum.reduce(Map.keys(state.requests), state, &cancel_request(&2, &1))
  end

  defp cancel_request(state, id) do
    case Map.pop(state.requests, id) do
      {nil, _requests} ->
        state

      {%{pid: pid, ref: ref}, requests} ->
        Task.Supervisor.terminate_child(state.task_supervisor, pid)
        Process.demonitor(ref, [:flush])
        %{state | requests: requests}
    end
  end

  defp remove_request(state, ref) do
    requests = Map.reject(state.requests, fn {_id, entry} -> entry.ref == ref end)
    %{state | requests: requests}
  end
end
