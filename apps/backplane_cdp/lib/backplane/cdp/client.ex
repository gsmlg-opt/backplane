defmodule Backplane.CDP.Client do
  @moduledoc """
  Bounded, single-command Chrome DevTools Protocol connections to local Chrome.

  Discovery always uses the configured loopback port. Each operation owns its
  connection in a separate process and never replays a command after a failure.
  """

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event

  @timeout 15_000
  @cleanup_timeout 1_000
  @max_discovery_bytes 1_048_576
  @max_message_bytes 16_777_216

  @spec pages(pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def pages(port) when is_integer(port) and port in 1..65_535 do
    isolated(fn deadline ->
      with {:ok, targets} <- targets(port, deadline) do
        {:ok, Enum.map(targets, &Map.take(&1, ~w(id title url)))}
      end
    end)
  end

  def pages(_port), do: {:error, "Invalid Chrome debugging port"}

  @doc "Returns a validated loopback WebSocket endpoint for a page target."
  def page_socket_url(port, target)
      when is_integer(port) and port in 1..65_535 and is_binary(target),
      do: isolated(&debugger_url(port, target, &1))

  def page_socket_url(_port, _target), do: {:error, "Invalid Chrome target"}

  @spec command(pos_integer(), :browser | String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def command(port, target, method, params)
      when is_integer(port) and port in 1..65_535 and is_binary(method) and is_map(params) do
    with :ok <- validate_method(method) do
      with_connection(port, target, &send_command(&1, method, params))
    end
  end

  def command(_port, _target, _method, _params), do: {:error, "Invalid CDP command arguments"}

  @doc "Runs related commands on one bounded connection, preserving session-scoped object IDs."
  def with_connection(port, target, operation, timeout \\ @timeout)

  def with_connection(port, target, operation, timeout)
      when is_integer(port) and port in 1..65_535 and is_function(operation, 1) and
             is_integer(timeout) and timeout in 1..120_000 do
    isolated(
      fn deadline ->
        with {:ok, url} <- debugger_url(port, target, deadline) do
          execute(url, operation, deadline)
        end
      end,
      timeout
    )
  end

  def with_connection(_port, _target, _operation, _timeout),
    do: {:error, "Invalid Chrome connection arguments"}

  @doc "Sends a CDP command on the connection owned by the current callback."
  def send_command(%{socket: socket, deadline: deadline, sequence: sequence}, method, params)
      when is_binary(method) and is_map(params) do
    with :ok <- validate_method(method) do
      id = :atomics.add_get(sequence, 1, 1)

      case WebSocket.send(socket, Formata.JSON.encode!(%{id: id, method: method, params: params})) do
        :ok -> await_result(socket, id, deadline)
        {:error, _reason} -> {:error, "Chrome command could not be sent"}
      end
    end
  end

  @doc """
  Consumes matching events as a command runs, acknowledging each event after
  `consume` returns `:ok`. The callback may stop the command with `{:error, message}`.
  Other events are discarded for this command, and the response is never replayed.
  """
  def stream_command(
        %{socket: socket, deadline: deadline, sequence: sequence},
        method,
        params,
        event_method,
        consume
      )
      when is_binary(method) and is_map(params) and is_binary(event_method) and
             is_function(consume, 1) do
    with :ok <- validate_method(method) do
      id = :atomics.add_get(sequence, 1, 1)

      case WebSocket.send(socket, Formata.JSON.encode!(%{id: id, method: method, params: params})) do
        :ok -> await_stream_result(socket, id, deadline, event_method, consume)
        {:error, _reason} -> {:error, "Chrome command could not be sent"}
      end
    end
  end

  @doc "Waits for a protocol event on the current bounded connection."
  def wait_for_event(%{socket: socket, deadline: deadline}, method, timeout)
      when is_binary(method) and is_integer(timeout) and timeout >= 0 do
    key = {__MODULE__, socket.ref}
    {before, rest} = Enum.split_while(Process.get(key, []), &(&1["method"] != method))

    case rest do
      [event | after_events] ->
        Process.put(key, before ++ after_events)
        {:ok, event["params"] || %{}}

      [] ->
        receive_event(socket, method, min(deadline, now() + timeout))
    end
  end

  defp isolated(operation, timeout \\ @timeout) do
    task = Task.async(fn -> operation.(now() + timeout) end)

    case Task.yield(task, timeout + 2 * @cleanup_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "Chrome operation timed out"}
    end
  end

  defp validate_method(method) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*\z/, method),
      do: :ok,
      else: {:error, "Invalid CDP method"}
  end

  defp targets(port, deadline) do
    case discovery(port, "/json/list", deadline) do
      {:ok, targets} when is_list(targets) ->
        {:ok, Enum.filter(targets, &page?/1)}

      {:ok, _} ->
        {:error, "Invalid Chrome target discovery response"}

      error ->
        error
    end
  end

  defp page?(%{"type" => "page", "id" => id, "title" => title, "url" => url}) do
    valid_id?(id) and is_binary(title) and is_binary(url)
  end

  defp page?(_target), do: false

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id)

  defp debugger_url(port, :browser, deadline) do
    with {:ok, %{"webSocketDebuggerUrl" => url}} <- discovery(port, "/json/version", deadline) do
      validate_url(url, port, "browser", nil)
    else
      {:ok, _} -> {:error, "Chrome did not provide a browser WebSocket URL"}
      error -> error
    end
  end

  defp debugger_url(port, page_id, deadline) when is_binary(page_id) do
    with true <- valid_id?(page_id),
         {:ok, targets} <- targets(port, deadline) do
      case Enum.find(targets, &(&1["id"] == page_id)) do
        %{"webSocketDebuggerUrl" => url} -> validate_url(url, port, "page", page_id)
        _ -> {:error, "Chrome page was not found"}
      end
    else
      false -> {:error, "Invalid Chrome page ID"}
      error -> error
    end
  end

  defp debugger_url(_port, _target, _deadline), do: {:error, "Invalid Chrome target"}

  defp validate_url(url, port, kind, page_id) when is_binary(url) do
    prefix = "/devtools/#{kind}/"

    with {:ok,
          %URI{
            scheme: "ws",
            host: host,
            port: ^port,
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          }} <- URI.new(url),
         true <- host in ["127.0.0.1", "localhost", "::1"] and is_binary(path),
         true <- String.starts_with?(path, prefix),
         id = String.replace_prefix(path, prefix, ""),
         true <- valid_id?(id) and (page_id == nil or page_id == id) do
      {:ok, "ws://127.0.0.1:#{port}#{path}"}
    else
      _ -> {:error, "Chrome returned an invalid local WebSocket URL"}
    end
  end

  defp validate_url(_url, _port, _kind, _id),
    do: {:error, "Chrome returned an invalid local WebSocket URL"}

  defp discovery(port, path, deadline) do
    promise =
      HTTP.fetch("http://127.0.0.1:#{port}#{path}",
        redirect: :manual,
        stream_response: true,
        decode_body: false,
        timeout: remaining(deadline),
        connect_timeout: min(remaining(deadline), 3_000),
        read_idle_timeout: 3_000,
        response_stream_idle_timeout: 3_000,
        response_stream_ack_timeout: 3_000,
        retry: false
      )

    try do
      case HTTP.Promise.await(promise, remaining(deadline)) do
        %HTTP.Response{status: 200} = response -> decode_discovery(response, deadline)
        %HTTP.Response{status: status} -> {:error, "Chrome discovery returned HTTP #{status}"}
        {:error, _reason} -> {:error, "Chrome discovery connection failed"}
      end
    after
      HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise), @cleanup_timeout)
    end
  end

  defp decode_discovery(response, deadline) do
    with {:ok, body} <- read_body(response, deadline),
         {:ok, value} <- Formata.JSON.decode(body) do
      {:ok, value}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Invalid JSON in Chrome discovery response"}
    end
  end

  defp read_body(%HTTP.Response{body: stream}, deadline) when is_pid(stream) do
    monitor = Process.monitor(stream)
    send(stream, {:read_chunk, self(), :ack})

    try do
      read_chunks(stream, monitor, deadline, [], 0)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp read_body(%HTTP.Response{body: body}, _deadline)
       when is_binary(body) and byte_size(body) <= @max_discovery_bytes,
       do: {:ok, body}

  defp read_body(_response, _deadline), do: {:error, "Chrome discovery response is too large"}

  defp read_chunks(stream, monitor, deadline, chunks, size) do
    receive do
      {:stream_chunk, ^stream, chunk, ack_ref} ->
        send(stream, {:stream_chunk_ack, ack_ref})

        if size + byte_size(chunk) <= @max_discovery_bytes do
          read_chunks(stream, monitor, deadline, [chunk | chunks], size + byte_size(chunk))
        else
          {:error, "Chrome discovery response is too large"}
        end

      {:stream_trailers, ^stream, _trailers} ->
        read_chunks(stream, monitor, deadline, chunks, size)

      {:stream_end, ^stream} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:stream_error, ^stream, _reason} ->
        {:error, "Chrome discovery response failed"}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, "Chrome discovery response failed"}
    after
      remaining(deadline) -> {:error, "Chrome discovery timed out"}
    end
  end

  defp execute(url, operation, deadline) do
    case WebSocket.new(url, [],
           delivery: :ack,
           connect_timeout: min(remaining(deadline), 3_000),
           opening_timeout: max(remaining(deadline), 1),
           write_timeout: 3_000,
           close_timeout: 500,
           max_message_size: @max_message_bytes,
           max_queue_events: 16,
           max_queue_bytes: @max_message_bytes + 1_048_576,
           telemetry_url: nil
         ) do
      %WebSocket{} = socket ->
        try do
          with :ok <- await_open(socket, deadline) do
            operation.(%{socket: socket, deadline: deadline, sequence: :atomics.new(1, [])})
          end
        after
          WebSocket.close(socket)
          HTTP.ClientCompletion.await(WebSocket.completion(socket), @cleanup_timeout)
        end

      {:error, _reason} ->
        {:error, "Chrome WebSocket connection failed"}
    end
  end

  defp await_open(socket, deadline) do
    receive do
      {WebSocket, ^socket, %Event.Open{}} -> :ok
      {WebSocket, ^socket, %Event.Error{}} -> {:error, "Chrome WebSocket connection failed"}
      {WebSocket, ^socket, %Event.Close{}} -> {:error, "Chrome WebSocket closed"}
    after
      remaining(deadline) -> {:error, "Chrome WebSocket connection timed out"}
    end
  end

  defp await_result(socket, id, deadline) do
    receive do
      {WebSocket, ^socket, %Event.Message{data: data}, ref} when is_binary(data) ->
        WebSocket.acknowledge(socket, ref)

        case Formata.JSON.decode(data) do
          {:ok, %{"id" => ^id, "result" => result}} when is_map(result) ->
            {:ok, result}

          {:ok, %{"id" => ^id, "error" => error}} ->
            cdp_error(error)

          {:ok, %{"method" => method} = event} when is_binary(method) ->
            remember_event(socket, event)
            await_result(socket, id, deadline)

          {:ok, %{"id" => _other}} ->
            await_result(socket, id, deadline)

          _ ->
            {:error, "Invalid Chrome protocol response"}
        end

      {WebSocket, ^socket, %Event.Message{}, ref} ->
        WebSocket.acknowledge(socket, ref)
        {:error, "Invalid Chrome protocol response"}

      {WebSocket, ^socket, %Event.Error{}} ->
        {:error, "Chrome WebSocket failed during command"}

      {WebSocket, ^socket, %Event.Close{}} ->
        {:error, "Chrome WebSocket closed during command"}
    after
      remaining(deadline) -> {:error, "Chrome command timed out"}
    end
  end

  defp cdp_error(%{"message" => message}) when is_binary(message),
    do: {:error, "Chrome protocol error: #{message}"}

  defp cdp_error(_error), do: {:error, "Chrome protocol command failed"}

  defp await_stream_result(socket, id, deadline, event_method, consume) do
    receive do
      {WebSocket, ^socket, %Event.Message{data: data}, ref} when is_binary(data) ->
        result = stream_message(Formata.JSON.decode(data), id, event_method, consume)
        WebSocket.acknowledge(socket, ref)

        case result do
          :continue -> await_stream_result(socket, id, deadline, event_method, consume)
          result -> result
        end

      {WebSocket, ^socket, %Event.Message{}, ref} ->
        WebSocket.acknowledge(socket, ref)
        {:error, "Invalid Chrome protocol response"}

      {WebSocket, ^socket, %Event.Error{}} ->
        {:error, "Chrome WebSocket failed during command"}

      {WebSocket, ^socket, %Event.Close{}} ->
        {:error, "Chrome WebSocket closed during command"}
    after
      remaining(deadline) -> {:error, "Chrome command timed out"}
    end
  end

  defp stream_message({:ok, %{"id" => id, "result" => result}}, id, _event_method, _consume)
       when is_map(result),
       do: {:ok, result}

  defp stream_message({:ok, %{"id" => id, "error" => error}}, id, _event_method, _consume),
    do: cdp_error(error)

  defp stream_message(
         {:ok, %{"method" => event_method, "params" => params}},
         _id,
         event_method,
         consume
       )
       when is_map(params) do
    case consume.(params) do
      :ok -> :continue
      {:error, _message} = error -> error
    end
  end

  defp stream_message({:ok, %{"method" => event_method}}, _id, event_method, _consume),
    do: {:error, "Invalid Chrome stream event"}

  defp stream_message({:ok, %{"method" => method}}, _id, _event_method, _consume)
       when is_binary(method),
       do: :continue

  defp stream_message({:ok, %{"id" => _other}}, _id, _event_method, _consume), do: :continue

  defp stream_message(_message, _id, _event_method, _consume),
    do: {:error, "Invalid Chrome protocol response"}

  defp remember_event(socket, event) do
    key = {__MODULE__, socket.ref}
    Process.put(key, Enum.take(Process.get(key, []) ++ [event], -128))
  end

  defp receive_event(socket, method, deadline) do
    receive do
      {WebSocket, ^socket, %Event.Message{data: data}, ref} when is_binary(data) ->
        WebSocket.acknowledge(socket, ref)

        case Formata.JSON.decode(data) do
          {:ok, %{"method" => ^method} = event} ->
            {:ok, event["params"] || %{}}

          {:ok, %{"method" => other} = event} when is_binary(other) ->
            remember_event(socket, event)
            receive_event(socket, method, deadline)

          {:ok, %{"id" => _id}} ->
            receive_event(socket, method, deadline)

          _ ->
            {:error, "Invalid Chrome protocol response"}
        end

      {WebSocket, ^socket, %Event.Error{}} ->
        {:error, "Chrome WebSocket failed while waiting for an event"}

      {WebSocket, ^socket, %Event.Close{}} ->
        {:error, "Chrome WebSocket closed while waiting for an event"}
    after
      remaining(deadline) -> {:error, "Chrome protocol event timed out"}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
