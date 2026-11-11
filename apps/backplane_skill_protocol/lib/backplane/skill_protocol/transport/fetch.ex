defmodule Backplane.SkillProtocol.Transport.Fetch do
  @moduledoc """
  Default `HTTP.fetch/2` transport for `Backplane.SkillProtocol.Client`.

  Performs one GET without redirects, retries or body decoding. The response
  body is streamed under the request's byte cap, overall deadline and
  cancellation callback, failing with `:response_too_large`, `:timeout` or
  `:cancelled` respectively. Response headers are returned as lowercase names
  mapped to their first value.
  """

  @poll_ms 25
  @cleanup_ms 1_000

  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(request) do
    request.url
    |> HTTP.fetch(
      method: "GET",
      headers: Enum.map(request.headers, fn {name, value} -> {to_string(name), value} end),
      redirect: :manual,
      timeout: request.timeout_ms,
      connect_timeout: request.timeout_ms,
      stream_response: true,
      error_mode: :structured
    )
    |> await_response(request)
  rescue
    exception -> {:error, exception}
  end

  # Structured errors keep a bare `{:error, :timeout}` unambiguous: it only
  # means this poll interval expired, so the request is still in flight.
  defp await_response(promise, request) do
    case HTTP.Promise.await(promise, poll_interval(request)) do
      %HTTP.Response{} = response ->
        read_response(response, promise, request)

      {:error, :timeout} ->
        case interruption(request) do
          nil -> await_response(promise, request)
          reason -> abort(promise, reason)
        end

      {:error, reason} ->
        if expired?(request), do: {:error, :timeout}, else: {:error, reason}
    end
  end

  defp read_response(response, promise, request) do
    with {:ok, body} <- read_body(response, promise, request) do
      {:ok, %{status: response.status, headers: first_headers(response), body: body}}
    end
  end

  defp read_body(response, promise, request) do
    case HTTP.Response.stream_pid(response) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)
        send(pid, {:read_chunk, self(), :ack})

        try do
          stream_loop(pid, monitor, promise, request, [], 0)
        after
          Process.demonitor(monitor, [:flush])
        end

      nil ->
        body = response.body || ""

        if byte_size(body) > request.max_bytes,
          do: {:error, :response_too_large},
          else: {:ok, body}
    end
  end

  defp stream_loop(pid, monitor, promise, request, acc, size) do
    receive do
      {:stream_chunk, ^pid, chunk, ack_ref} ->
        send(pid, {:stream_chunk_ack, ack_ref})
        stream_chunk(pid, monitor, promise, request, acc, size, chunk)

      {:stream_chunk, ^pid, chunk} ->
        stream_chunk(pid, monitor, promise, request, acc, size, chunk)

      {:stream_end, ^pid} ->
        {:ok, IO.iodata_to_binary(acc)}

      {:stream_error, ^pid, reason} ->
        if expired?(request), do: {:error, :timeout}, else: {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:stream_down, reason}}
    after
      poll_interval(request) ->
        case interruption(request) do
          nil -> stream_loop(pid, monitor, promise, request, acc, size)
          reason -> stop(pid, promise, reason)
        end
    end
  end

  defp stream_chunk(pid, monitor, promise, request, acc, size, chunk) do
    size = size + byte_size(chunk)

    cond do
      request.cancelled?.() -> stop(pid, promise, :cancelled)
      expired?(request) -> stop(pid, promise, :timeout)
      size > request.max_bytes -> stop(pid, promise, :response_too_large)
      true -> stream_loop(pid, monitor, promise, request, [acc, chunk], size)
    end
  end

  defp interruption(request) do
    cond do
      request.cancelled?.() -> :cancelled
      expired?(request) -> :timeout
      true -> nil
    end
  end

  defp stop(pid, promise, reason) do
    HTTP.Stream.stop(pid, reason)
    abort(promise, reason)
  end

  defp abort(promise, reason) do
    case HTTP.Promise.completion(promise) do
      nil -> :ok
      completion -> HTTP.RequestCompletion.abort_and_await(completion, @cleanup_ms)
    end

    {:error, reason}
  end

  defp first_headers(%HTTP.Response{headers: %HTTP.Headers{headers: headers}}) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.put_new(acc, name |> to_string() |> String.downcase(), to_string(value))
    end)
  end

  defp expired?(request), do: now() >= request.deadline

  defp poll_interval(request), do: request.deadline |> Kernel.-(now()) |> max(0) |> min(@poll_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
