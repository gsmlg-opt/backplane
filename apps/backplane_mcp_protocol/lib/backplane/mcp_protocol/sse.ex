defmodule Backplane.McpProtocol.SSE do
  @moduledoc false

  use Backplane.McpProtocol.Logging

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.HTTP.Lifecycle
  alias Backplane.McpProtocol.Logging
  alias Backplane.McpProtocol.SSE.Parser

  @connection_headers %{
    "accept" => "text/event-stream",
    "cache-control" => "no-cache",
    "connection" => "keep-alive"
  }

  @default_http_opts [
    receive_timeout: :infinity,
    request_timeout: :infinity,
    max_reconnections: 5,
    default_backoff: to_timeout(second: 1),
    max_backoff: to_timeout(second: 15)
  ]

  @retry_opts [:max_reconnections, :default_backoff, :max_backoff]

  @doc """
  Connects to a server-sent event stream.

  ## Parameters

    - `server_url` - the URL of the server to connect to.
    - `headers` - additional headers to send with the request.
    - `opts` - additional options to pass to the HTTP client.

  ## Examples

      iex> Backplane.McpProtocol.SSE.connect("http://localhost:4000")
      #Stream<[ref: 1, task: #PID<0.123.0>]>

  """
  @spec connect(String.t(), map(), Keyword.t()) :: Enumerable.t()
  def connect(server_url, headers \\ %{}, opts \\ []) do
    opts = Keyword.merge(@default_http_opts, opts)
    {transport, opts} = Keyword.pop(opts, :transport_opts, [])
    opts = Keyword.merge(transport, opts)

    with {:ok, uri} <- parse_uri(server_url) do
      headers = headers |> Map.merge(@connection_headers) |> Map.to_list()

      req = HTTP.build(:get, uri, headers)
      ref = make_ref()
      task = spawn_stream_task(req, ref, opts)

      Stream.resource(
        fn -> {ref, task, ""} end,
        &process_task_stream/1,
        &shutdown_task/1
      )
    end
  end

  defp parse_uri(url) do
    with {:error, _} <- URI.new(url), do: {:error, :invalid_url}
  end

  defp spawn_stream_task(%{url: _} = req, ref, opts) do
    dest = Keyword.get(opts, :dest, self())

    fun = fn -> loop_sse_stream(req, ref, dest, opts) end

    case Process.get(:mcp_http_lifecycle) do
      {lifecycle, _job} ->
        {:ok, pid} = Lifecycle.start(lifecycle, fun)
        pid

      nil ->
        spawn_link(fun)
    end
  end

  defp loop_sse_stream(req, ref, dest, opts, attempt \\ 1) do
    {retry, http} = Keyword.split(opts, @retry_opts)

    if attempt <= max(retry[:max_reconnections], 1) do
      max_backoff = retry[:max_backoff]
      base_backoff = retry[:default_backoff]
      backoff = calculate_reconnect_backoff(attempt, max_backoff, base_backoff)

      on_chunk = &process_sse_stream(&1, &2, dest, ref)

      case HTTP.stream_while(req, nil, on_chunk, Keyword.delete(http, :dest)) do
        {:ok, _acc} ->
          Logging.transport_event("sse_reconnect", %{
            reason: "success",
            attempt: attempt,
            max_attempts: retry[:max_reconnections]
          })

          Process.sleep(backoff)
          loop_sse_stream(req, ref, dest, opts, attempt + 1)

        {:error, exc, _acc} ->
          Logging.transport_event(
            "sse_reconnect",
            %{
              reason: "error",
              error: inspect(exc),
              attempt: attempt,
              max_attempts: retry[:max_reconnections]
            },
            level: :error
          )

          Process.sleep(backoff + to_timeout(second: 1))
          loop_sse_stream(req, ref, dest, opts, attempt + 1)
      end
    else
      send(dest, {:chunk, :halted, ref})

      Logging.transport_event(
        "sse_max_reconnects",
        %{
          max_attempts: retry[:max_reconnections]
        },
        level: :error
      )
    end
  end

  defp calculate_reconnect_backoff(attempt, max, base) do
    min(max, attempt ** 2 * base)
  end

  # the raw streaming response
  defp process_sse_stream({:status, status}, acc, _dest, _ref) when status != 200, do: {:halt, acc}

  defp process_sse_stream(chunk, acc, dest, ref) do
    send(dest, {:chunk, chunk, ref})
    {:cont, acc}
  end

  defp process_task_stream({ref, task, buffer} = state) do
    receive do
      {:chunk, {:data, data}, ^ref} ->
        {events, buffer} = parse_chunk(buffer, data)
        {events, {ref, task, buffer}}

      {:chunk, {:status, status}, ^ref} ->
        Logging.transport_event("sse_status", status)
        {[], state}

      {:chunk, {:headers, headers}, ^ref} ->
        Logging.transport_event("sse_headers", headers)
        {[], state}

      {:chunk, :halted, ^ref} ->
        Logging.transport_event("sse_halted", "Transport will be restarted")
        {[{:error, :halted}], state}

      {:chunk, unknown, ^ref} ->
        Logging.transport_event("sse_unknown_chunk", unknown)
        {[], state}
    end
  end

  @doc false
  def parse_chunk(buffer, chunk) do
    data = buffer <> chunk

    case :binary.match(data, ["\r\n\r\n", "\n\n", "\r\r"]) do
      {position, _size} when position > 1_048_576 ->
        raise ArgumentError, "SSE frame exceeds buffer limit"

      {position, size} ->
        <<frame::binary-size(position), _separator::binary-size(size), rest::binary>> = data
        {events, rest} = parse_chunk("", rest)
        {Parser.run(frame <> "\n\n") ++ events, rest}

      :nomatch when byte_size(data) <= 1_048_576 ->
        {[], data}

      :nomatch ->
        raise ArgumentError, "SSE frame exceeds buffer limit"
    end
  end

  defp shutdown_task({_ref, task, _buffer}), do: Process.exit(task, :kill)
end
