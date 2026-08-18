defmodule Backplane.McpProtocol.Transport.StreamableHTTP do
  @moduledoc """
  A transport implementation that uses Streamable HTTP as specified in MCP 2025-03-26.

  This transport communicates with MCP servers via HTTP POST requests for sending messages
  and optionally uses Server-Sent Events (SSE) for receiving streaming responses.

  ## Usage

      # Start the transport with a base URL
      {:ok, transport} = Backplane.McpProtocol.Transport.StreamableHTTP.start_link(
        client: client_pid,
        base_url: "http://localhost:8000",
        mcp_path: "/mcp"
      )

      # Send a message
      :ok = Backplane.McpProtocol.Transport.StreamableHTTP.send_message(transport, encoded_message)

  ## Session Management

  The transport automatically handles MCP session IDs via the `mcp-session-id` header:
  - Extracts session ID from server responses
  - Includes session ID in subsequent requests
  - Maintains session state throughout the connection lifecycle
  - Handles session expiration (404 responses) by reinitializing

  ## Response Handling

  Based on the response status and content type:
  - 202 Accepted: Message acknowledged, no immediate response
  - 200 OK with application/json: Single JSON response forwarded to client
  - 200 OK with text/event-stream: SSE stream parsed and events forwarded to client
  - 404 Not Found: Session expired, triggers reinitialization

  ## SSE Support

  The transport can establish a separate GET connection for server-initiated messages.
  This allows the server to send requests and notifications without a client request.
  """

  @behaviour Backplane.McpProtocol.Transport
  @behaviour Backplane.McpProtocol.Transport.Behaviour

  use GenServer
  use Backplane.McpProtocol.Logging

  import Peri

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.SSE
  alias Backplane.McpProtocol.SSE.Event
  alias Backplane.McpProtocol.Telemetry
  alias Backplane.McpProtocol.Transport.Behaviour, as: Transport
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers
  alias Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeaders
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Stream

  @legacy_protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26)
  @sse_retry_ms 1_000

  @type t :: GenServer.server()
  @type params_t :: Enumerable.t(option)

  @type http_state :: %{
          session_id: String.t() | nil,
          last_event_id: String.t() | nil
        }

  @impl Backplane.McpProtocol.Transport
  @spec transport_init(keyword()) :: {:ok, http_state()} | {:error, term()}
  def transport_init(opts \\ []) do
    {:ok,
     %{
       session_id: Keyword.get(opts, :session_id),
       last_event_id: Keyword.get(opts, :last_event_id)
     }}
  end

  @impl Backplane.McpProtocol.Transport
  @spec parse(binary() | map(), http_state()) ::
          {:ok, [map()], http_state()} | {:error, term()}
  def parse(raw, state) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = message} ->
        {:ok, [message], state}

      {:ok, messages} when is_list(messages) ->
        if Enum.all?(messages, &is_map/1) do
          {:ok, messages, state}
        else
          {:error, :invalid_message}
        end

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  def parse(raw, state) when is_map(raw) do
    {:ok, [raw], state}
  end

  @impl Backplane.McpProtocol.Transport
  @spec encode(map(), http_state()) :: {:ok, binary(), http_state()} | {:error, term()}
  def encode(message, state) when is_map(message) do
    {:ok, JSON.encode!(message), state}
  rescue
    e ->
      {:error, {:encode_error, Exception.message(e)}}
  end

  @impl Backplane.McpProtocol.Transport
  @spec extract_metadata(term(), http_state()) :: map()
  def extract_metadata(headers, state) when is_list(headers) do
    session_id = find_header(headers, "mcp-session-id") || state.session_id

    %{
      transport: :streamable_http,
      session_id: session_id
    }
  end

  def extract_metadata(_raw_input, state) do
    %{
      transport: :streamable_http,
      session_id: state.session_id
    }
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == String.downcase(name), do: value

      _ ->
        nil
    end)
  end

  @typedoc """
  The options for the Streamable HTTP transport.

  - `:url` - The exact MCP endpoint URL (e.g. http://localhost:8000/custom/mcp).
  - `:base_url` - The base URL of the MCP server (e.g. http://localhost:8000).
  - `:mcp_path` - The MCP endpoint path (e.g. /mcp) (default "/mcp").
  - `:client` - The client to send the messages to.
  - `:headers` - The headers to send with the HTTP requests.
  - `:headers_provider` - A zero-arity function that resolves additional headers for every request.
  - `:transport_opts` - The underlying HTTP transport options.
  - `:http_options` - The underlying HTTP client options.
  - `:enable_sse` - Whether to establish a GET connection for server-initiated messages (default false).
  """
  @type option ::
          {:name, GenServer.name()}
          | {:client, GenServer.server()}
          | {:url, String.t()}
          | {:base_url, String.t()}
          | {:mcp_path, String.t()}
          | {:headers, map()}
          | {:headers_provider, RequestHeaders.provider() | nil}
          | {:transport_opts, keyword}
          | {:http_options, Finch.request_opts()}
          | {:enable_sse, boolean()}
          | GenServer.option()

  defschema(:options_schema, %{
    name: {{:custom, &Backplane.McpProtocol.genserver_name/1}, {:default, __MODULE__}},
    client: {:required, Backplane.McpProtocol.get_schema(:process_name)},
    url: {:string, {:transform, &URI.new!/1}},
    base_url: {:string, {:transform, &URI.new!/1}},
    mcp_path: {:string, {:default, "/mcp"}},
    headers: {:map, {:default, %{}}},
    headers_provider: {:any, {:default, nil}},
    transport_opts: {:any, {:default, []}},
    http_options: {:any, {:default, []}},
    enable_sse: {:boolean, {:default, false}}
  })

  @impl Transport
  @spec start_link(params_t) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = options_schema!(opts)
    opts = Map.new(opts)
    opts = Map.put(opts, :mcp_url, resolve_mcp_url(opts))
    GenServer.start_link(__MODULE__, opts, name: opts.name)
  end

  @impl Transport
  def send_message(pid \\ __MODULE__, message, opts) when is_binary(message) do
    timeout = Keyword.get(opts, :timeout, 5000)
    request_context = Keyword.get(opts, :request_context)
    GenServer.call(pid, {:send, message, timeout, request_context}, timeout)
  end

  @impl Transport
  def open_stream(pid \\ __MODULE__, message, opts) when is_binary(message) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(pid, {:open_stream, message, opts}, timeout)
  end

  @impl Transport
  def close_stream(pid \\ __MODULE__, stream, opts)

  def close_stream(_pid, stream, opts) when is_pid(stream) and is_list(opts) do
    case Keyword.get(opts, :timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> Stream.close(stream, timeout)
      _invalid -> {:error, :invalid_timeout}
    end
  end

  def close_stream(_pid, _stream, _opts), do: {:error, :invalid_stream}

  @impl Transport
  def shutdown(pid \\ __MODULE__) do
    GenServer.cast(pid, :close_connection)
  end

  @impl Transport
  def supported_protocol_versions, do: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  @impl GenServer
  def init(opts) do
    state = %{
      client: opts.client,
      mcp_url: opts.mcp_url,
      headers: opts.headers,
      headers_provider: opts.headers_provider,
      transport_opts: opts.transport_opts,
      http_options: opts.http_options,
      session_id: nil,
      enable_sse: Map.get(opts, :enable_sse, false),
      sse_task: nil,
      last_event_id: nil,
      legacy_protocol_version: nil,
      active_request: nil
    }

    emit_telemetry(:init, state)
    {:ok, state, {:continue, :connect}}
  end

  defp resolve_mcp_url(opts) do
    case {Map.get(opts, :url), Map.get(opts, :base_url)} do
      {%URI{}, %URI{}} ->
        raise ArgumentError, "provide only one of url or base_url"

      {%URI{} = url, nil} ->
        url

      {nil, %URI{} = base_url} ->
        URI.append_path(base_url, opts.mcp_path)

      {nil, nil} ->
        raise ArgumentError, "provide url or base_url"
    end
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    emit_telemetry(:connect, state)
    GenServer.cast(state.client, :negotiate)
    new_state = maybe_start_sse_connection(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:open_stream, message, opts}, _from, state) do
    context = Keyword.get(opts, :request_context)
    owner = Keyword.get(opts, :owner)
    subscription_id = Keyword.get(opts, :subscription_id)

    with %RequestContext{era: :modern, method: "subscriptions/listen"} <- context,
         true <- is_pid(owner),
         true <- is_binary(subscription_id) or is_integer(subscription_id),
         {:ok, stream} <-
           Stream.start(%{
             owner: owner,
             transport: self(),
             mcp_url: state.mcp_url,
             headers: state.headers,
             headers_provider: state.headers_provider,
             http_options: state.http_options,
             encoded_request: message,
             request_context: context,
             subscription_id: subscription_id
           }) do
      {:reply, {:ok, stream}, state}
    else
      false -> {:reply, {:error, :invalid_stream_owner}, state}
      %RequestContext{} -> {:reply, {:error, :unsupported_stream}, state}
      nil -> {:reply, {:error, :missing_request_context}, state}
      {:error, _reason} = error -> {:reply, error, state}
      _invalid -> {:reply, {:error, :unsupported_stream}, state}
    end
  end

  def handle_call({:send, message, timeout, request_context}, from, state) do
    state = persist_legacy_protocol_version(state, request_context)

    emit_telemetry(:send, state, %{message_size: byte_size(message)})

    Logging.transport_event("sending_http_request", %{
      url: URI.to_string(state.mcp_url),
      size: byte_size(message),
      timeout: timeout
    })

    new_state = %{state | active_request: from}

    case send_http_request(new_state, message, timeout, request_context) do
      {:ok, response} ->
        Logging.transport_event("got_http_response", %{status: response.status})
        handle_response(response, new_state, request_context)

      {:error, {:http_error, 404, _body} = reason} ->
        if legacy_request?(request_context) and not is_nil(state.session_id) do
          Logging.transport_event("session_expired", %{has_session: true})
          GenServer.cast(state.client, :session_expired)

          {:reply, {:error, :session_expired},
           %{state | session_id: nil, last_event_id: nil, legacy_protocol_version: nil}}
        else
          Logging.transport_event("http_request_error", %{reason: inspect(reason)}, level: :error)
          log_error(reason)
          {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        Logging.transport_event("http_request_error", %{reason: inspect(reason)}, level: :error)

        log_error(reason)
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast(:close_connection, state) do
    if state.session_id, do: delete_session(state)
    if state.sse_task, do: Process.exit(state.sse_task, :kill)

    {:stop, :normal, %{state | session_id: nil, sse_task: nil, last_event_id: nil, legacy_protocol_version: nil}}
  end

  @impl GenServer
  def handle_info({:sse_event, event}, state) do
    {:noreply, handle_sse_event(event, state)}
  end

  @impl GenServer
  def handle_info({:sse_response_event, event}, state) do
    {:noreply, handle_sse_event(event, state)}
  end

  @impl GenServer
  def handle_info(:sse_response_complete, state) do
    if state.active_request, do: GenServer.reply(state.active_request, :ok)
    {:noreply, %{state | active_request: nil}}
  end

  @impl GenServer
  def handle_info({:sse_closed, {:headers_error, reason}}, state) do
    Logging.transport_event(
      "sse_headers_failed",
      %{reason: sanitize_headers_error(reason)},
      level: :warning
    )

    Process.send_after(self(), :retry_sse, @sse_retry_ms)
    {:noreply, %{state | sse_task: nil}}
  end

  def handle_info(:retry_sse, state) do
    {:noreply, maybe_start_sse_connection(state)}
  end

  def handle_info({:sse_closed, reason}, state) do
    Logging.transport_event("sse_connection_closed", %{reason: reason})
    new_state = maybe_start_sse_connection(%{state | sse_task: nil})
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when state.sse_task != nil do
    if pid == state.sse_task do
      Logging.transport_event("sse_task_down", %{reason: reason})
      new_state = maybe_start_sse_connection(%{state | sse_task: nil})
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logging.transport_event("unexpected_message", %{message: msg})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    if state.sse_task, do: Process.exit(state.sse_task, :kill)
    if state.session_id, do: delete_session(state)

    emit_telemetry(:terminate, state, %{reason: reason})
  end

  # Private functions

  defp send_http_request(state, message, timeout, request_context) do
    with {:ok, request_headers} <-
           RequestHeaders.resolve(state.headers, state.headers_provider),
         {:ok, headers} <- Headers.build(request_headers, message, request_context) do
      headers =
        if legacy_request?(request_context) do
          headers
          |> maybe_put_persisted_legacy_protocol_header(state, request_context)
          |> put_session_header(state.session_id)
        else
          headers
        end

      # Set receive_timeout, ensuring it takes precedence over any default in http_options.
      # transport_opts configure Finch pools and are not individual request options.
      options = Keyword.put(state.http_options, :receive_timeout, timeout)
      url = URI.to_string(state.mcp_url)

      Logging.transport_event("http_request", %{
        method: :post,
        url: url,
        header_names: headers |> Map.keys() |> Enum.sort(),
        timeout: timeout
      })

      request = HTTP.build(:post, url, headers, message)

      request
      |> HTTP.follow_redirect(options)
      |> case do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} = error ->
          Logging.transport_event("http_request_failed", %{reason: reason}, level: :error)

          error
      end
    end
  end

  defp handle_response(%{headers: headers, body: body, status: status}, state, request_context) do
    new_state =
      state
      |> update_session_id(headers, request_context)
      |> update_legacy_protocol_version(body, request_context)
      |> maybe_start_sse_on_session_acquired(state, request_context)

    Logging.transport_event("http_response", %{
      status: status,
      content_type: get_content_type(headers),
      body_size: byte_size(body),
      has_session: not is_nil(new_state.session_id)
    })

    case {status, get_content_type(headers)} do
      {202, _} ->
        {:reply, :ok, %{new_state | active_request: nil}}

      {_, "application/json"} ->
        forward_to_client(body, new_state)
        {:reply, :ok, %{new_state | active_request: nil}}

      {_, "text/event-stream"} ->
        stream_sse_response(body, new_state)
        {:noreply, new_state}

      {_, content_type} ->
        {:reply, {:error, {:unsupported_content_type, content_type}}, %{new_state | active_request: nil}}
    end
  end

  defp forward_to_client(message, %{client: client} = state) do
    emit_telemetry(:receive, state, %{message_size: byte_size(message)})
    GenServer.cast(client, {:response, message})
  end

  defp stream_sse_response(body, state) do
    parent = self()

    Task.start(fn ->
      body
      |> SSE.Parser.run()
      |> Enum.each(fn event ->
        send(parent, {:sse_response_event, event})
      end)

      send(parent, :sse_response_complete)
    end)
  rescue
    e ->
      Logging.transport_event("sse_parse_error", %{error: e}, level: :warning)

      if state.active_request do
        GenServer.reply(state.active_request, {:error, :sse_parse_error})
      end
  end

  defp handle_sse_event({:error, :halted}, state) do
    Logging.transport_event("sse_halted", "SSE stream ended")
    state
  end

  defp handle_sse_event(%Event{data: data, id: id}, state) do
    new_state = if id, do: %{state | last_event_id: id}, else: state
    forward_to_client(data, new_state)
    new_state
  end

  defp handle_sse_event(event, state) do
    Logging.transport_event("unknown_sse_event", event, level: :warning)
    state
  end

  defp put_session_header(headers, nil), do: headers

  defp put_session_header(headers, session_id), do: Map.put(headers, "mcp-session-id", session_id)

  defp maybe_put_persisted_legacy_protocol_header(headers, state, nil) do
    Headers.put_legacy_protocol_header(headers, state.legacy_protocol_version)
  end

  defp maybe_put_persisted_legacy_protocol_header(headers, _state, _request_context), do: headers

  defp update_session_id(state, headers, request_context) do
    if session_initialization?(request_context) do
      case get_header(headers, "mcp-session-id") do
        nil -> state
        session_id -> %{state | session_id: session_id}
      end
    else
      state
    end
  end

  defp update_legacy_protocol_version(state, body, %RequestContext{era: :legacy, method: "initialize"}) do
    case negotiated_protocol_version(body) do
      version when version in @legacy_protocol_versions ->
        %{state | legacy_protocol_version: version}

      _invalid_or_unnegotiated ->
        state
    end
  end

  defp update_legacy_protocol_version(state, _body, _request_context), do: state

  defp negotiated_protocol_version(body) do
    case protocol_version_from_json(body) do
      nil ->
        body
        |> SSE.Parser.run()
        |> Enum.find_value(fn
          %Event{data: data} -> protocol_version_from_json(data)
          _other -> nil
        end)

      version ->
        version
    end
  rescue
    _malformed_sse -> nil
  end

  defp protocol_version_from_json(encoded) do
    case JSON.decode(encoded) do
      {:ok, %{"result" => %{"protocolVersion" => version}}} when is_binary(version) -> version
      _invalid -> nil
    end
  end

  defp get_header(headers, name) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == String.downcase(name) end)
    |> case do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_content_type(headers) do
    headers
    |> get_header("content-type")
    |> case do
      nil -> "application/json"
      value -> value |> String.split(";") |> List.first() |> String.trim()
    end
  end

  defp emit_telemetry(event, state, extra_metadata \\ %{}) do
    metadata = %{
      transport: :streamable_http,
      mcp_url: URI.to_string(state.mcp_url),
      client: state.client
    }

    event_name =
      case event do
        :init -> Telemetry.event_transport_init()
        :connect -> Telemetry.event_transport_connect()
        :send -> Telemetry.event_transport_send()
        :receive -> Telemetry.event_transport_receive()
        :terminate -> Telemetry.event_transport_terminate()
      end

    Telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      Map.merge(metadata, extra_metadata)
    )
  end

  defp log_error({:http_error, status, body}) do
    Logging.transport_event("http_error", %{status: status, body: body}, level: :error)
  end

  defp log_error(reason) do
    Logging.transport_event("request_error", %{reason: reason}, level: :error)
  end

  # Additional helper functions for SSE support

  defp maybe_start_sse_connection(%{enable_sse: false} = state), do: state

  defp maybe_start_sse_connection(%{enable_sse: true, session_id: nil} = state), do: state

  defp maybe_start_sse_connection(%{enable_sse: true, sse_task: task} = state) when not is_nil(task), do: state

  defp maybe_start_sse_connection(%{enable_sse: true} = state) do
    pid = start_sse_task(state)
    %{state | sse_task: pid}
  end

  defp maybe_start_sse_on_session_acquired(new_state, old_state, request_context) do
    if legacy_request?(request_context) do
      maybe_start_legacy_sse_on_session_acquired(new_state, old_state)
    else
      new_state
    end
  end

  defp maybe_start_legacy_sse_on_session_acquired(%{session_id: nil} = new_state, _old_state), do: new_state

  defp maybe_start_legacy_sse_on_session_acquired(new_state, %{session_id: nil}) do
    maybe_start_sse_connection(new_state)
  end

  defp maybe_start_legacy_sse_on_session_acquired(new_state, _old_state), do: new_state

  defp start_sse_task(state) do
    parent = self()
    {:ok, pid} = Task.start(fn -> run_sse_task(parent, state) end)
    Process.monitor(pid)
    pid
  end

  defp run_sse_task(parent, state) do
    options = state.http_options

    case build_sse_headers(state) do
      {:ok, headers} ->
        request = HTTP.build(:get, URI.to_string(state.mcp_url), headers, nil)
        process_sse_request(request, options, parent)
        send(parent, {:sse_closed, :normal})

      {:error, reason} ->
        send(parent, {:sse_closed, {:headers_error, reason}})
    end
  end

  defp build_sse_headers(state) do
    with {:ok, request_headers} <-
           RequestHeaders.resolve(state.headers, state.headers_provider),
         {:ok, configured_headers} <- Headers.legacy_configured(request_headers) do
      headers =
        configured_headers
        |> Headers.put_legacy_protocol_header(state.legacy_protocol_version)
        |> Map.put("accept", "text/event-stream")
        |> put_session_header(state.session_id)
        |> put_last_event_id_header(state.last_event_id)

      {:ok, headers}
    end
  end

  defp process_sse_request(request, options, parent) do
    case HTTP.follow_redirect(request, options) do
      {:ok, %{status: 200, headers: resp_headers, body: body}} ->
        handle_sse_response(resp_headers, body, parent)

      {:ok, %{status: 405}} ->
        Logging.transport_event(
          "sse_not_supported",
          "Server returned 405 for GET request"
        )

      error ->
        Logging.transport_event("sse_connection_failed", %{error: error}, level: :warning)
    end
  end

  defp handle_sse_response(headers, body, parent) do
    if get_content_type(headers) == "text/event-stream" do
      body
      |> SSE.Parser.run()
      |> Enum.each(fn event -> send(parent, {:sse_event, event}) end)
    end
  end

  defp delete_session(state) do
    options = state.http_options

    with {:ok, request_headers} <-
           RequestHeaders.resolve(state.headers, state.headers_provider),
         {:ok, configured_headers} <- Headers.legacy_configured(request_headers),
         headers =
           configured_headers
           |> Headers.put_legacy_protocol_header(state.legacy_protocol_version)
           |> put_session_header(state.session_id),
         %Finch.Request{} = request <-
           HTTP.build(:delete, URI.to_string(state.mcp_url), headers, nil),
         {:ok, %{status: status}} when status in [200, 405] <-
           HTTP.follow_redirect(request, options) do
      :ok
    else
      error ->
        Logging.transport_event("session_delete_failed", %{error: error}, level: :debug)
        :ok
    end
  end

  defp put_last_event_id_header(headers, nil), do: headers

  defp put_last_event_id_header(headers, event_id), do: Map.put(headers, "last-event-id", event_id)

  defp sanitize_headers_error(reason) when is_atom(reason), do: reason

  defp sanitize_headers_error({reason, _detail})
       when reason in [:duplicate_header, :invalid_header, :invalid_header_name, :invalid_header_value],
       do: reason

  defp sanitize_headers_error(_reason), do: :request_headers_unavailable

  defp legacy_request?(nil), do: true
  defp legacy_request?(%RequestContext{era: :legacy}), do: true
  defp legacy_request?(_request_context), do: false

  defp persist_legacy_protocol_version(state, %RequestContext{era: :legacy, method: method, protocol_version: version})
       when method != "initialize" and version in @legacy_protocol_versions do
    %{state | legacy_protocol_version: version}
  end

  defp persist_legacy_protocol_version(state, _request_context), do: state

  defp session_initialization?(nil), do: true

  defp session_initialization?(%RequestContext{era: :legacy, method: "initialize"}), do: true

  defp session_initialization?(_request_context), do: false
end
