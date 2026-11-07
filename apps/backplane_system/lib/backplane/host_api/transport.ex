defmodule Backplane.HostApi.Transport do
  @moduledoc """
  Bounded request ownership for API calls over authenticated host connections.

  The API channel owns authentication. Each connection replaces its predecessor
  atomically; replies are accepted only from the channel that admitted the call.
  A response frame is acknowledged only after its consumer calls `ack/2`.
  """
  use GenServer

  @max_request_bytes 384 * 1024
  @max_chunk_bytes 48 * 1024
  @max_response_bytes 50_000_000
  @max_pending 8
  @header_name ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/
  @codes ~w(upstream_error timeout cancelled invalid_request service_unavailable unsupported_api response_too_large too_many_requests invalid_response)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.put_new(opts, :name, __MODULE__)]}
    }
  end

  def max_request_bytes, do: @max_request_bytes

  def connect(host_id, channel, server \\ __MODULE__),
    do: GenServer.call(server, {:connect, host_id, channel})

  def ready(host_id, channel, services, server \\ __MODULE__),
    do: GenServer.call(server, {:ready, host_id, channel, services})

  def invalidate(host_id, channel, server \\ __MODULE__),
    do: GenServer.call(server, {:invalidate, host_id, channel})

  def disconnect(host_id, channel, server \\ __MODULE__),
    do: GenServer.call(server, {:disconnect, host_id, channel})

  def open(host_id, service_id, revision, payload, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 120_000)
    GenServer.call(server, {:open, host_id, service_id, revision, payload, timeout})
  end

  def deliver(host_id, channel, payload, reply_ref, server \\ __MODULE__),
    do: GenServer.call(server, {:deliver, host_id, channel, payload, reply_ref})

  def ack(request_id, server \\ __MODULE__), do: GenServer.call(server, {:ack, request_id})
  def cancel(request_id, server \\ __MODULE__), do: GenServer.call(server, {:cancel, request_id})

  def fail(host_id, channel, request_id, reason, server \\ __MODULE__),
    do: GenServer.call(server, {:fail, host_id, channel, request_id, reason})

  @impl true
  def init(_), do: {:ok, %{connections: %{}, pending: %{}}}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
    |> Map.put(:reason, :redacted)
  end

  @impl true
  def handle_call({:connect, host, channel}, _from, state) when is_pid(channel) do
    state = retire_host(state, host, :not_connected)
    connection = %{channel: channel, monitor: Process.monitor(channel), ready: %{}}
    {:reply, :ok, put_in(state, [:connections, host], connection)}
  end

  def handle_call({:ready, host, channel, services}, _from, state) when is_map(services) do
    case state.connections[host] do
      %{channel: ^channel} ->
        {:reply, :ok, put_in(state, [:connections, host, :ready], services)}

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:invalidate, host, channel}, _from, state) do
    case state.connections[host] do
      %{channel: ^channel} ->
        state = retire_requests(state, fn call -> call.host == host end, :service_unavailable)
        {:reply, :ok, put_in(state, [:connections, host, :ready], %{})}

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:disconnect, host, channel}, _from, state) do
    case state.connections[host] do
      %{channel: ^channel} -> {:reply, :ok, retire_host(state, host, :not_connected)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:open, host, service, revision, payload, timeout}, {owner, _}, state) do
    with %{channel: channel, ready: ready} <- state.connections[host],
         true <- is_integer(revision) and revision > 0 and Map.get(ready, service) == revision,
         true <- Enum.count(state.pending, fn {_, call} -> call.host == host end) < @max_pending,
         :ok <- validate_request(payload, timeout) do
      id = Ecto.UUID.generate()
      timer = Process.send_after(self(), {:idle, id}, timeout)

      call = %{
        owner: owner,
        monitor: Process.monitor(owner),
        host: host,
        channel: channel,
        timer: timer,
        timeout: timeout,
        phase: :headers,
        sequence: 0,
        bytes: 0,
        ack: nil,
        terminal: false
      }

      payload =
        Map.merge(payload, %{
          "protocol" => "host_api.v1",
          "request_id" => id,
          "service_id" => service,
          "service_revision" => revision,
          "timeout_ms" => timeout
        })

      send(channel, {:host_api_request, id, payload})
      {:reply, {:ok, id}, put_in(state, [:pending, id], call)}
    else
      nil -> {:reply, {:error, :not_connected}, state}
      false -> {:reply, {:error, :service_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deliver, host, channel, payload, reply_ref}, _from, state) do
    id = if is_map(payload), do: payload["request_id"]

    with %{host: ^host, channel: ^channel, ack: nil, terminal: false} = call <- state.pending[id],
         {:ok, frame, call} <- frame(payload, call) do
      Process.cancel_timer(call.timer)
      timer = Process.send_after(self(), {:idle, id}, call.timeout)
      call = %{call | ack: reply_ref, timer: timer}
      send(call.owner, {:host_api_frame, id, frame})
      {:reply, :ok, put_in(state, [:pending, id], call)}
    else
      _ -> {:reply, {:error, :invalid_response}, state}
    end
  end

  def handle_call({:ack, id}, {owner, _}, state) do
    case state.pending[id] do
      %{owner: ^owner, ack: ref} = call when not is_nil(ref) ->
        send(call.channel, {:host_api_ack, ref, :ok})

        if call.terminal do
          {:reply, :ok, delete_call(state, id)}
        else
          {:reply, :ok, put_in(state, [:pending, id, :ack], nil)}
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel, id}, {owner, _}, state) do
    case state.pending[id] do
      %{owner: ^owner} = call ->
        cancel_remote(call, id)
        {:reply, :ok, delete_call(state, id)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:fail, host, channel, id, reason}, _from, state) do
    case state.pending[id] do
      %{host: ^host, channel: ^channel} = call ->
        {:reply, :ok, retire_call(state, id, call, reason)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:idle, id}, state) do
    case state.pending[id] do
      nil -> {:noreply, state}
      call -> {:noreply, retire_call(state, id, call, :timeout)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.connections, state, fn {host, connection}, acc ->
        if connection.monitor == ref, do: retire_host(acc, host, :not_connected), else: acc
      end)

    state =
      Enum.reduce(state.pending, state, fn {id, call}, acc ->
        if call.monitor == ref do
          cancel_remote(call, id)
          delete_call(acc, id)
        else
          acc
        end
      end)

    {:noreply, state}
  end

  defp validate_request(%{"body_base64" => encoded, "headers" => headers, "api" => api}, timeout)
       when is_binary(encoded) and byte_size(encoded) <= 524_288 and
              is_integer(timeout) and timeout in 1..300_000 and
              api in ~w(openai_embeddings openai_chat_completions openai_responses anthropic_messages) do
    with {:ok, body} <- Base.decode64(encoded),
         true <- byte_size(body) <= @max_request_bytes,
         true <- valid_headers?(headers) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_request(_, _), do: {:error, :invalid_request}

  defp frame(
         %{"type" => "headers", "status" => status, "headers" => headers},
         %{phase: :headers} = call
       )
       when is_integer(status) and status in 200..599 do
    if valid_headers?(headers),
      do: {:ok, {:headers, status, headers}, %{call | phase: :body}},
      else: {:error, :invalid_response}
  end

  defp frame(
         %{"type" => "chunk", "sequence" => sequence, "data" => data},
         %{phase: :body, sequence: sequence} = call
       )
       when is_binary(data) and byte_size(data) <= 65_536 do
    with {:ok, decoded} <- Base.decode64(data),
         true <- byte_size(decoded) <= @max_chunk_bytes,
         bytes = call.bytes + byte_size(decoded),
         true <- bytes <= @max_response_bytes do
      {:ok, {:chunk, decoded}, %{call | sequence: sequence + 1, bytes: bytes}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp frame(%{"type" => "done"}, %{phase: :body} = call),
    do: {:ok, :done, %{call | terminal: true}}

  defp frame(%{"type" => "error", "code" => code}, call) when code in @codes,
    do: {:ok, {:error, code}, %{call | terminal: true}}

  defp frame(_, _), do: {:error, :invalid_response}

  defp valid_headers?(headers) when is_list(headers) and length(headers) <= 100 do
    Enum.all?(headers, fn
      [name, value] when is_binary(name) and is_binary(value) ->
        byte_size(name) <= 256 and byte_size(value) <= 8192 and
          Regex.match?(@header_name, name) and
          not String.contains?(name <> value, ["\r", "\n", <<0>>])

      _ ->
        false
    end) and :erlang.external_size(headers) <= 16_384
  end

  defp valid_headers?(_), do: false

  defp retire_host(state, host, reason) do
    case state.connections[host] do
      nil ->
        state

      connection ->
        Process.demonitor(connection.monitor, [:flush])
        state = retire_requests(state, &(&1.host == host), reason)
        %{state | connections: Map.delete(state.connections, host)}
    end
  end

  defp retire_requests(state, predicate, reason) do
    Enum.reduce(state.pending, state, fn {id, call}, acc ->
      if predicate.(call), do: retire_call(acc, id, call, reason), else: acc
    end)
  end

  defp retire_call(state, id, call, reason) do
    send(call.owner, {:host_api_error, id, reason})
    cancel_remote(call, id)
    delete_call(state, id)
  end

  defp cancel_remote(call, id) do
    if call.ack, do: send(call.channel, {:host_api_ack, call.ack, {:error, :cancelled}})
    send(call.channel, {:host_api_cancel, id})
  end

  defp delete_call(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {call, pending} ->
        Process.cancel_timer(call.timer)
        Process.demonitor(call.monitor, [:flush])
        %{state | pending: pending}
    end
  end
end
