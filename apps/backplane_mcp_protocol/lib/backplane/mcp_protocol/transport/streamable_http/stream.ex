defmodule Backplane.McpProtocol.Transport.StreamableHTTP.Stream do
  @moduledoc """
  Owns one modern request-scoped POST/SSE exchange.

  A small controller remains responsive to owner, transport, and explicit close
  signals while a linked worker blocks in Finch. The worker carries an
  incremental SSE frame buffer so arbitrary TCP chunk boundaries never become
  protocol message boundaries.
  """

  use GenServer

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.SSE.Parser
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @max_sse_buffer_bytes 1_048_576

  defmodule State do
    @moduledoc false
    defstruct [
      :owner,
      :owner_monitor,
      :transport,
      :transport_monitor,
      :subscription_id,
      :worker,
      :worker_monitor,
      :request
    ]
  end

  @spec start(map()) :: GenServer.on_start()
  def start(opts) when is_map(opts), do: GenServer.start(__MODULE__, opts)

  @spec close(pid(), timeout()) :: :ok | {:error, term()}
  def close(pid, timeout \\ 5_000)

  def close(pid, timeout) when is_pid(pid) and is_integer(timeout) and timeout > 0 do
    GenServer.stop(pid, :normal, timeout)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:timeout, _call} -> {:error, :stream_close_timeout}
    :exit, reason -> {:error, {:stream_close_exit, reason}}
  end

  def close(pid, _timeout) when is_pid(pid), do: {:error, :invalid_timeout}

  @impl GenServer
  def init(opts) do
    owner = Map.fetch!(opts, :owner)
    transport = Map.fetch!(opts, :transport)
    Process.flag(:trap_exit, true)

    state = %State{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      transport: transport,
      transport_monitor: Process.monitor(transport),
      subscription_id: Map.fetch!(opts, :subscription_id),
      request: opts
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state) do
    controller = self()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          request = Map.put(state.request, :controller, controller)
          send(controller, {:stream_result, self(), run_stream(request)})
        end,
        [:link, :monitor]
      )

    {:noreply, %{state | worker: worker, worker_monitor: monitor}}
  end

  @impl GenServer
  def handle_info({:stream_payload, worker, encoded}, %{worker: worker} = state) do
    case decode_subscription_message(encoded, state.subscription_id) do
      {:ok, message} ->
        send(state.owner, {:mcp_stream_message, self(), state.subscription_id, message})

      :drop ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:stream_result, worker, :ok}, %{worker: worker} = state) do
    state = clear_worker_monitor(state)
    send(state.owner, {:mcp_stream_closed, self(), :normal})
    {:stop, :normal, state}
  end

  def handle_info({:stream_result, worker, {:error, reason}}, %{worker: worker} = state) do
    state = clear_worker_monitor(state)
    send(state.owner, {:mcp_stream_error, self(), reason})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{owner: pid, owner_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{transport: pid, transport_monitor: ref} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{worker: pid, worker_monitor: ref} = state
      ) do
    send(state.owner, {:mcp_stream_error, self(), {:stream_worker_down, reason}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, worker, _reason}, %{worker: worker} = state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_reference(state.worker_monitor), do: Process.demonitor(state.worker_monitor, [:flush])
    if is_reference(state.owner_monitor), do: Process.demonitor(state.owner_monitor, [:flush])

    if is_reference(state.transport_monitor),
      do: Process.demonitor(state.transport_monitor, [:flush])

    if is_pid(state.worker) and Process.alive?(state.worker) do
      Process.exit(state.worker, :kill)
    end

    :ok
  end

  defp run_stream(opts) do
    with {:ok, headers} <-
           Headers.build(opts.headers, opts.encoded_request, opts.request_context),
         %Finch.Request{} = request <-
           HTTP.build(:post, URI.to_string(opts.mcp_url), headers, opts.encoded_request) do
      initial = %{
        controller: opts.controller,
        worker: self(),
        status: nil,
        headers: [],
        validated?: false,
        buffer: "",
        error: nil
      }

      stream_options =
        opts.http_options
        |> Keyword.put(:receive_timeout, :infinity)
        |> Keyword.put(:request_timeout, :infinity)

      case Finch.stream_while(
             request,
             Backplane.McpProtocol.Finch,
             initial,
             &stream_entry/2,
             stream_options
           ) do
        {:ok, %{error: nil}} -> :ok
        {:ok, %{error: reason}} -> {:error, reason}
        {:error, reason, %{error: nil}} -> {:error, reason}
        {:error, _finch_reason, %{error: reason}} -> {:error, reason}
      end
    end
  rescue
    exception -> {:error, {:stream_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:stream_exit, reason}}
  end

  defp stream_entry({:status, status}, acc) when status in 200..299 do
    {:cont, %{acc | status: status}}
  end

  defp stream_entry({:status, status}, acc) do
    reason = {:http_error, status}
    {:halt, %{acc | status: status, error: reason}}
  end

  defp stream_entry({:headers, headers}, %{error: nil} = acc) do
    case content_type(headers) do
      "text/event-stream" ->
        {:cont, %{acc | headers: headers, validated?: true}}

      content_type ->
        {:halt, %{acc | headers: headers, error: {:unsupported_content_type, content_type}}}
    end
  end

  defp stream_entry({:headers, headers}, acc), do: {:halt, %{acc | headers: headers}}

  defp stream_entry({:data, data}, %{validated?: true, error: nil} = acc) when is_binary(data) do
    {frames, buffer} = extract_frames(acc.buffer <> data, [])

    if byte_size(buffer) > @max_sse_buffer_bytes or
         Enum.any?(frames, &(byte_size(&1) > @max_sse_buffer_bytes)) do
      {:halt, %{acc | error: :sse_buffer_too_large}}
    else
      Enum.each(frames, fn frame ->
        frame
        |> Parser.run()
        |> Enum.each(fn event ->
          send(acc.controller, {:stream_payload, acc.worker, event.data})
        end)
      end)

      {:cont, %{acc | buffer: buffer}}
    end
  end

  defp stream_entry({:data, _data}, acc),
    do: {:halt, %{acc | error: acc.error || :unvalidated_stream_data}}

  defp stream_entry({:trailers, _trailers}, acc), do: {:cont, acc}

  defp extract_frames(buffer, frames) do
    case next_separator(buffer) do
      {position, length} ->
        <<frame::binary-size(position), _separator::binary-size(length), rest::binary>> = buffer
        extract_frames(rest, [normalize_frame(frame) | frames])

      nil ->
        {Enum.reverse(frames), buffer}
    end
  end

  defp next_separator(buffer) do
    ["\r\n\r\n", "\n\n", "\r\r"]
    |> Enum.flat_map(fn separator ->
      case :binary.match(buffer, separator) do
        {position, length} -> [{position, length}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "content-type", do: value

      _invalid ->
        nil
    end)
    |> case do
      nil -> nil
      value -> value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp normalize_frame(frame) do
    frame
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> Kernel.<>("\n\n")
  end

  defp decode_subscription_message(encoded, expected_id) do
    with {:ok, message} when is_map(message) <- JSON.decode(encoded),
         true <- subscription_message?(message, expected_id) do
      {:ok, message}
    else
      _invalid_or_foreign -> :drop
    end
  end

  defp subscription_message?(
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "result" => %{"_meta" => %{@subscription_id_key => id}}
         } = message,
         id
       ) do
    not Map.has_key?(message, "method") and not Map.has_key?(message, "error")
  end

  defp subscription_message?(
         %{"jsonrpc" => "2.0", "id" => id, "error" => %{} = error} = message,
         id
       ) do
    is_integer(error["code"]) and is_binary(error["message"]) and
      not Map.has_key?(message, "method") and not Map.has_key?(message, "result")
  end

  defp subscription_message?(
         %{
           "jsonrpc" => "2.0",
           "method" => method,
           "params" => %{"_meta" => %{@subscription_id_key => id}}
         } = message,
         id
       )
       when is_binary(method) do
    not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
      not Map.has_key?(message, "error")
  end

  defp subscription_message?(_message, _expected_id), do: false

  defp clear_worker_monitor(%State{worker_monitor: monitor} = state) when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    %{state | worker_monitor: nil}
  end

  defp clear_worker_monitor(state), do: state
end
