defmodule Backplane.McpProtocol.Transport.SSE do
  @moduledoc """
  A transport implementation that uses Server-Sent Events (SSE) for receiving messages
  and HTTP POST requests for sending messages back to the server.

  > #### Deprecated {: .warning}
  >
  > This transport has been deprecated as of MCP specification 2025-03-26 in favor
  > of the Streamable HTTP transport (`Backplane.McpProtocol.Transport.StreamableHTTP`).
  >
  > The HTTP+SSE transport from protocol version 2024-11-05 has been replaced by
  > the more flexible Streamable HTTP transport which supports optional SSE streaming
  > on a single endpoint.
  >
  > For new implementations, please use `Backplane.McpProtocol.Transport.StreamableHTTP` instead.
  > This module is maintained for backward compatibility with servers using the
  > 2024-11-05 protocol version.

  > ## Notes {: .info}
  >
  > For initialization and setup, check our [Installation & Setup](./installation.html) and
  > the [Transport options](./transport_options.html) guides for reference.
  """

  @behaviour Backplane.McpProtocol.Transport
  @behaviour Backplane.McpProtocol.Transport.Behaviour

  use GenServer
  use Backplane.McpProtocol.Logging

  import Peri

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.HTTP.Lifecycle
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.SSE
  alias Backplane.McpProtocol.SSE.Event
  alias Backplane.McpProtocol.Telemetry
  alias Backplane.McpProtocol.Transport.Behaviour, as: Transport

  @deprecated "Use Backplane.McpProtocol.Transport.StreamableHTTP instead"

  @type t :: GenServer.server()

  @type sse_state :: %{
          message_url: String.t() | nil,
          last_event_id: String.t() | nil
        }

  @impl Backplane.McpProtocol.Transport
  @spec transport_init(keyword()) :: {:ok, sse_state()} | {:error, term()}
  def transport_init(opts \\ []) do
    {:ok,
     %{
       message_url: Keyword.get(opts, :message_url),
       last_event_id: Keyword.get(opts, :last_event_id)
     }}
  end

  @impl Backplane.McpProtocol.Transport
  @spec parse(binary() | map(), sse_state()) ::
          {:ok, [map()], sse_state()} | {:error, term()}
  def parse(raw, state) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = message} ->
        {:ok, [message], state}

      {:ok, _} ->
        {:error, :invalid_message}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  def parse(raw, state) when is_map(raw) do
    {:ok, [raw], state}
  end

  @impl Backplane.McpProtocol.Transport
  @spec encode(map(), sse_state()) :: {:ok, binary(), sse_state()} | {:error, term()}
  def encode(message, state) when is_map(message) do
    {:ok, JSON.encode!(message) <> "\n", state}
  rescue
    e ->
      {:error, {:encode_error, Exception.message(e)}}
  end

  @impl Backplane.McpProtocol.Transport
  @spec extract_metadata(term(), sse_state()) :: map()
  def extract_metadata(%Event{id: id, event: event_type}, state) do
    %{
      transport: :sse,
      event_type: event_type,
      event_id: id,
      message_url: state.message_url
    }
  end

  def extract_metadata(_raw_input, state) do
    %{
      transport: :sse,
      message_url: state.message_url
    }
  end

  @typedoc """
  The options for the MCP server.

  - `:base_url` - The base URL of the MCP server (e.g. http://localhost:8000) (required).
  - `:base_path` - The base path of the MCP server (e.g. /mcp).
  - `:sse_path` - The path to the SSE endpoint (e.g. /mcp/sse) (default `:base_path` + `/sse`).
  """
  @type server ::
          Enumerable.t(
            {:base_url, String.t()}
            | {:base_path, String.t()}
            | {:sse_path, String.t()}
          )

  @type params_t :: Enumerable.t(option)
  @typedoc """
  The options for the SSE transport.

  - `:name` - The name of the transport process, respecting the `GenServer` "Name Registration" section.
  - `:client` - The client to send the messages to, respecting the `GenServer` "Name Registration" section.
  - `:server` - The server configuration.
  - `:headers` - The headers to send with the HTTP requests.
  - `:transport_opts` - The SSE reconnection/backoff options.
  - `:http_options` - The Fetch HTTP options (request_timeout, receive_timeout, connect_timeout, ssl, socket_opts).
    Set `allowed_origin: url` to confine the connection, redirects and advertised message endpoints to that origin.
  """
  @type option ::
          {:name, GenServer.name()}
          | {:client, GenServer.server()}
          | {:server, server}
          | {:headers, map()}
          | {:transport_opts, keyword}
          | {:http_options, keyword()}
          | GenServer.option()

  defschema(:options_schema, %{
    one_shot: {:boolean, {:default, false}},
    activation_id: {:any, {:default, nil}},
    name: {{:custom, &Backplane.McpProtocol.genserver_name/1}, {:default, __MODULE__}},
    client:
      {:required,
       {:oneof,
        [
          {:custom, &Backplane.McpProtocol.genserver_name/1},
          :pid,
          {:tuple, [:atom, :any]}
        ]}},
    server: [
      base_url: {:required, {:string, {:transform, &URI.new!/1}}},
      base_path: {:string, {:default, "/"}},
      sse_path: {:string, {:default, "/sse"}}
    ],
    headers: {:map, {:default, %{}}},
    transport_opts: {:any, {:default, []}},
    http_options: {:any, {:default, []}}
  })

  @impl Transport
  @spec start_link(params_t) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = options_schema!(opts)
    GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @doc false
  @impl true
  def cancel_request(pid, request_id, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    opts = Keyword.put_new(opts, :deadline, System.monotonic_time(:millisecond) + timeout)

    GenServer.call(
      pid,
      {:cancel_owned_request, request_id, opts},
      Keyword.fetch!(opts, :timeout) + 100
    )
  end

  @doc false
  def pin_request(pid, id, opts),
    do: GenServer.call(pid, {:pin_request, id}, Keyword.fetch!(opts, :timeout))

  @doc false
  def unpin_request(pid, id, _opts),
    do: GenServer.cast(pid, {:unpin_request, id})

  @impl Transport
  def send_message(pid, message, opts) when is_binary(message) do
    timeout = Keyword.get(opts, :timeout, 5000)

    deadline =
      Keyword.get(
        opts,
        :deadline,
        if(timeout == :infinity,
          do: :infinity,
          else: System.monotonic_time(:millisecond) + timeout
        )
      )

    GenServer.call(pid, {:send, message, deadline}, timeout)
  end

  @impl Transport
  def shutdown(pid) do
    GenServer.cast(pid, :close_connection)
  end

  @impl Transport
  def close(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    if is_integer(timeout) and timeout > 0 do
      GenServer.call(pid, {:close, opts}, timeout + 200)
    else
      {:error, Error.protocol(:invalid_params, %{reason: :invalid_cleanup_timeout})}
    end
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_report_unavailable)}
  end

  @impl Transport
  def cleanup_status(pid) do
    GenServer.call(pid, :cleanup_status)
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_report_unavailable)}
  end

  @impl Transport
  def supported_protocol_versions do
    ["2024-11-05"]
  end

  @impl GenServer
  def format_status(status) do
    Map.update!(status, :state, fn state ->
      Enum.reduce(
        [:headers, :transport_opts, :http_options],
        state,
        &Map.replace(&2, &1, :redacted)
      )
    end)
  end

  @impl GenServer
  def init(%{} = opts) do
    server_url = URI.append_path(opts.server[:base_url], opts.server[:base_path])
    sse_url = URI.append_path(server_url, opts.server[:sse_path])

    with :ok <- HTTP.validate_options(opts.http_options),
         :ok <- HTTP.validate_options(opts.transport_opts),
         :ok <- HTTP.check_origin(sse_url, Keyword.get(opts.http_options, :allowed_origin)),
         {:ok, lifecycle} <- Lifecycle.start_link(:sse, opts.activation_id) do
      state =
        opts
        |> Map.merge(%{
          message_url: nil,
          stream_task: nil,
          lifecycle: lifecycle,
          closing: false,
          pending: %{},
          request_pins: MapSet.new(),
          request_jobs: %{}
        })
        |> Map.put(:http_options, Keyword.merge(opts.transport_opts, opts.http_options))
        |> Map.put(:server_url, server_url)
        |> Map.put(:sse_url, sse_url)

      metadata = %{
        server_url: URI.to_string(server_url),
        sse_url: URI.to_string(sse_url),
        transport: :sse,
        client: opts.client
      }

      Telemetry.execute(
        Telemetry.event_transport_init(),
        %{system_time: System.system_time()},
        metadata
      )

      {:ok, state, {:continue, :connect}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    parent = self()
    parent_metadata = Logger.metadata()

    metadata = %{
      transport: :sse,
      sse_url: URI.to_string(state.sse_url)
    }

    Telemetry.execute(
      Telemetry.event_transport_connect(),
      %{system_time: System.system_time()},
      metadata
    )

    task =
      Lifecycle.start(
        state.lifecycle,
        fn ->
          Logger.metadata(parent_metadata)

          stream =
            SSE.connect(
              state.sse_url,
              state.headers,
              Keyword.merge(state.transport_opts, state.http_options)
            )

          process_stream(stream, parent)
        end,
        :consumer
      )

    {:ok, task} = task
    Process.monitor(task)

    {:noreply, %{state | stream_task: task}}
  end

  defp process_stream(stream, pid) do
    Enum.each(stream, &handle_sse_event(&1, pid))
  end

  defp handle_sse_event({:error, :halted}, pid) do
    Backplane.McpProtocol.Logging.transport_event("sse_halted", "Transport will be restarted")
    shutdown(pid)
  end

  defp handle_sse_event(%Event{event: "endpoint", data: endpoint}, pid) do
    Backplane.McpProtocol.Logging.transport_event("endpoint", endpoint)
    send(pid, {:endpoint, endpoint})
  end

  defp handle_sse_event(%Event{event: "message", data: data}, pid) do
    Backplane.McpProtocol.Logging.transport_event("message", data)
    send(pid, {:message, data})
  end

  # coming from fast-mcp ruby
  # https://github.com/yjacquin/fast-mcp/issues/38
  defp handle_sse_event(%Event{event: "ping", data: data}, _) do
    Backplane.McpProtocol.Logging.transport_event("ping", data)
  end

  defp handle_sse_event(%Event{event: "reconnect", data: data}, _pid) do
    reason =
      case JSON.decode(data) do
        {:ok, %{"reason" => reason}} -> reason
        _ -> "unknown"
      end

    Backplane.McpProtocol.Logging.transport_event("reconnect", %{reason: reason, data: data})
  end

  defp handle_sse_event(event, _pid) do
    Backplane.McpProtocol.Logging.transport_event("unknown", event, level: :warning)
  end

  @impl GenServer
  def handle_call(:cleanup_status, _from, state) do
    {:reply, Lifecycle.status(state.lifecycle), state}
  end

  def handle_call({:close, opts}, from, state) do
    lifecycle = state.lifecycle
    spawn(fn -> GenServer.reply(from, Lifecycle.close(lifecycle, opts)) end)

    Enum.each(state.pending, fn {_ref, {caller, _context, _worker}} ->
      GenServer.reply(caller, {:error, :closing})
    end)

    {:noreply, %{state | closing: true, pending: %{}}}
  end

  def handle_call(_request, _from, %{closing: true} = state) do
    {:reply, {:error, :closing}, state}
  end

  def handle_call({:send, _, _deadline}, _from, %{message_url: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:pin_request, id}, _from, state),
    do: {:reply, :ok, %{state | request_pins: MapSet.put(state.request_pins, id)}}

  def handle_call({:cancel_owned_request, request_id, opts}, from, state) do
    case Map.fetch(state.request_jobs, request_id) do
      {:ok, worker} ->
        lifecycle = state.lifecycle

        Task.Supervisor.start_child(Backplane.McpProtocol.Client.OperationSupervisor, fn ->
          GenServer.reply(from, Lifecycle.release_job(lifecycle, worker, opts))
        end)

        # A cancelled HTTP worker cannot deliver its normal result. Release
        # only that worker's retained call while keeping shared work pending.
        pending =
          Map.reject(state.pending, fn {_ref, {_caller, _context, pid}} -> pid == worker end)

        {:noreply, %{state | pending: pending}}

      :error ->
        {:reply, {:error, :request_cleanup_unknown}, state}
    end
  end

  def handle_call({:send, message, deadline}, from, state) do
    parent = self()
    ref = make_ref()

    {:ok, worker} =
      Lifecycle.start(
        state.lifecycle,
        fn ->
          result =
            case remaining(deadline) do
              0 ->
                {:error, :timeout}

              timeout ->
                {request, options} = make_message_request(message, state, timeout)

                case HTTP.follow_redirect(request, options) do
                  {:ok, %{status: status}} when status in 200..299 -> :ok
                  {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
                  {:error, reason} -> {:error, reason}
                end
            end

          send(parent, {:http_result, ref, result})
        end,
        if(tracked_wire?(state, message), do: :tracked_request, else: :request)
      )

    request_jobs =
      case JSON.decode(message) do
        {:ok, %{"id" => id}} -> Map.put(state.request_jobs, id, worker)
        _ -> state.request_jobs
      end

    request_jobs =
      if map_size(request_jobs) > 128 do
        case Enum.find(request_jobs, fn {id, pid} ->
               not MapSet.member?(state.request_pins, id) and not Process.alive?(pid)
             end) do
          {id, _pid} -> Map.delete(request_jobs, id)
          nil -> request_jobs
        end
      else
        request_jobs
      end

    state = %{state | request_jobs: request_jobs}
    {:noreply, put_in(state.pending[ref], {from, nil, worker})}
  end

  @impl GenServer
  def handle_info({:http_result, ref, result}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, _, _worker}, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_message, %{closing: true} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:endpoint, endpoint}, %{client: client, server_url: server_url} = state) do
    case URI.new(endpoint) do
      {:ok, endpoint} ->
        message_url = parse_message_url(URI.parse(server_url), endpoint)

        case HTTP.check_origin(message_url, Keyword.get(state.http_options, :allowed_origin)) do
          :ok ->
            GenServer.cast(client, :initialize)
            {:noreply, %{state | message_url: message_url}}

          {:error, _reason} ->
            {:stop, :cross_origin_endpoint, state}
        end

      {:error, _} = err ->
        {:stop, err, state}
    end
  end

  def handle_info({:message, message}, %{client: client} = state) do
    Telemetry.execute(
      Telemetry.event_transport_receive(),
      %{system_time: System.system_time()},
      %{
        transport: :sse,
        message_size: byte_size(message)
      }
    )

    GenServer.cast(client, {:response, message})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{stream_task: pid} = state) do
    Logging.transport_event("stream_terminated", %{reason: reason}, level: :error)

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{
        transport: :sse,
        reason: reason
      }
    )

    {:stop, {:stream_terminated, reason}, state}
  end

  def handle_info(msg, state) do
    Logging.transport_event("unexpected_message", %{message: msg})
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:unpin_request, id}, state) do
    case state.request_jobs[id] do
      nil -> :ok
      worker -> Lifecycle.unpin_job(state.lifecycle, worker)
    end

    {:noreply,
     %{
       state
       | request_pins: MapSet.delete(state.request_pins, id),
         request_jobs: Map.delete(state.request_jobs, id)
     }}
  end

  def handle_cast(:close_connection, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, %{stream_task: task}) when not is_nil(task) do
    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{
        transport: :sse,
        reason: reason
      }
    )

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{
        transport: :sse,
        reason: reason
      }
    )

    Process.exit(task, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp make_message_request(message, %{message_url: endpoint} = state, timeout) do
    request = HTTP.build(:post, endpoint, state.headers, message)

    options =
      Enum.reduce(
        [request_timeout: 15_000, receive_timeout: 15_000, connect_timeout: 10_000],
        state.http_options,
        fn {key, default}, options ->
          Keyword.put(options, key, min_timeout(Keyword.get(options, key, default), timeout))
        end
      )

    {request, options}
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp min_timeout(:infinity, timeout), do: timeout
  defp min_timeout(timeout, :infinity), do: timeout
  defp min_timeout(left, right), do: min(left, right)

  # Handles multiple possible formats for message_url URI.
  defp parse_message_url(%{path: base_path} = base, %{scheme: nil, host: nil, path: path} = uri)
       when is_binary(base_path) and is_binary(path) do
    if path =~ base_path do
      base
      |> URI.merge(uri)
      |> URI.to_string()
    else
      base
      |> URI.append_path(URI.to_string(uri))
      |> URI.to_string()
    end
  end

  defp parse_message_url(base, uri) do
    base
    |> URI.merge(uri)
    |> URI.to_string()
  end

  defp tracked_wire?(state, message) do
    case JSON.decode(message) do
      {:ok, %{"id" => id}} -> MapSet.member?(state.request_pins, id)
      _ -> false
    end
  end
end
