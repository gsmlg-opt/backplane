defmodule Backplane.HostAgent.ApiRequest do
  @moduledoc "Executes one declared host API request with acknowledged response chunks."

  alias Backplane.HostAgent.HTTPBody

  @derive {Inspect, only: [:request_id, :api]}
  defstruct [:request_id, :service_id, :api, :endpoint_url, :headers, :body, :timeout_ms]

  @apis ~w(openai_embeddings openai_chat_completions openai_responses anthropic_messages)
  @max_request_bytes 384 * 1024
  @max_response_bytes 50_000_000
  @chunk_bytes 48 * 1024
  @request_header_name ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/
  @blocked_request_headers ~w(host cookie cookie2 forwarded x-real-ip connection keep-alive te trailer transfer-encoding upgrade content-length accept-encoding)
  @timeout_reasons [:timeout, :await_timeout, :read_idle_timeout, :idle_timeout]
  @hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade content-length set-cookie)

  def apis, do: @apis
  def max_request_bytes, do: @max_request_bytes
  def chunk_bytes, do: @chunk_bytes

  def valid_url?(url) when is_binary(url) and byte_size(url) <= 4096 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def valid_url?(_url), do: false

  def prepare(payload, services) when is_map(payload) and is_map(services) do
    with %{
           "protocol" => "host_api.v1",
           "request_id" => id,
           "service_id" => service_id,
           "api" => api,
           "service_revision" => revision,
           "body_base64" => encoded
         } <- payload,
         true <- valid_id?(id) and valid_id?(service_id) and api in @apis,
         %{endpoints: endpoints, revision: ^revision} <- Map.get(services, service_id),
         {:ok, endpoint} <- endpoint(endpoints, api),
         {:ok, body} <- decode_body(encoded),
         {:ok, headers} <- request_headers(Map.get(payload, "headers", [])),
         timeout when is_integer(timeout) and timeout in 1..300_000 <-
           Map.get(payload, "timeout_ms", 120_000) do
      {:ok,
       %__MODULE__{
         request_id: id,
         service_id: service_id,
         api: api,
         endpoint_url: endpoint,
         headers: headers,
         body: body,
         timeout_ms: timeout
       }}
    else
      nil -> {:error, :service_unavailable}
      %{revision: _revision} -> {:error, :service_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  def prepare(_payload, _services), do: {:error, :invalid_request}

  def valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128

  @doc "The push callback must acknowledge each frame before the next is read."
  def run(%__MODULE__{} = request, push) when is_function(push, 1) do
    do_run(request, push)
  rescue
    _error -> emit_error(push, request.request_id, :upstream_error)
  catch
    _kind, _reason -> emit_error(push, request.request_id, :upstream_error)
  end

  defp do_run(request, push) do
    transfer = %{headers?: false, sequence: 0, bytes: 0, error: nil}
    deadline = System.monotonic_time(:millisecond) + request.timeout_ms
    idle_timeout = min(request.timeout_ms, 120_000)

    fetch_options = [
      method: "POST",
      headers: request.headers,
      body: request.body,
      redirect: :manual,
      decode_body: false,
      stream_response: true,
      timeout: request.timeout_ms,
      connect_timeout: min(request.timeout_ms, 10_000),
      read_idle_timeout: idle_timeout,
      response_stream_idle_timeout: idle_timeout,
      response_stream_ack_timeout: request.timeout_ms
    ]

    request.endpoint_url
    |> HTTP.fetch(fetch_options)
    |> HTTP.Promise.await(request.timeout_ms + 5_000)
    |> handle_response(transfer, deadline, request.request_id, push)
  end

  defp handle_response(%HTTP.Response{} = response, transfer, deadline, id, push) do
    response = %{status: response.status, headers: response_headers(response), raw: response}

    forward = fn bytes, transfer ->
      case forward_bytes(transfer, response, bytes, id, push) do
        {:ok, transfer} -> {:cont, transfer}
        {:error, code, transfer} -> {:halt, %{transfer | error: code}}
      end
    end

    case HTTPBody.reduce(response.raw, deadline, transfer, forward) do
      {:ok, transfer} ->
        with {:ok, _transfer} <- forward_headers(transfer, response, id, push) do
          push.(%{"request_id" => id, "type" => "done"})
        end

      {:halt, transfer} ->
        emit_error(push, id, transfer.error)

      {:error, reason, _transfer} ->
        emit_error(push, id, error_code(reason))
    end
  end

  defp handle_response({:error, reason}, _transfer, _deadline, id, push),
    do: emit_error(push, id, error_code(reason))

  defp handle_response(_other, _transfer, _deadline, id, push),
    do: emit_error(push, id, :upstream_error)

  defp response_headers(%HTTP.Response{headers: %HTTP.Headers{headers: headers}}) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp forward_bytes(transfer, response, bytes, id, push) do
    if transfer.bytes + byte_size(bytes) <= @max_response_bytes do
      with {:ok, transfer} <- forward_headers(transfer, response, id, push) do
        forward_chunks(bytes, transfer, id, push)
      end
    else
      {:error, :response_too_large, transfer}
    end
  end

  defp forward_headers(%{headers?: true} = transfer, _response, _id, _push),
    do: {:ok, transfer}

  defp forward_headers(transfer, response, id, push) do
    headers =
      response.headers
      |> Enum.reject(fn {name, _value} -> name in @hop_headers end)
      |> Enum.map(fn {name, value} -> [name, value] end)

    case push.(%{
           "request_id" => id,
           "type" => "headers",
           "status" => response.status,
           "headers" => headers
         }) do
      {:ok, _reply} -> {:ok, %{transfer | headers?: true}}
      :ok -> {:ok, %{transfer | headers?: true}}
      _error -> {:error, :cancelled, transfer}
    end
  end

  defp forward_chunks(<<>>, transfer, _id, _push), do: {:ok, transfer}

  defp forward_chunks(bytes, transfer, id, push) do
    size = min(byte_size(bytes), @chunk_bytes)
    <<chunk::binary-size(^size), rest::binary>> = bytes

    case push.(%{
           "request_id" => id,
           "type" => "chunk",
           "sequence" => transfer.sequence,
           "data" => Base.encode64(chunk)
         }) do
      {:ok, _reply} ->
        transfer = %{transfer | sequence: transfer.sequence + 1, bytes: transfer.bytes + size}
        forward_chunks(rest, transfer, id, push)

      :ok ->
        transfer = %{transfer | sequence: transfer.sequence + 1, bytes: transfer.bytes + size}
        forward_chunks(rest, transfer, id, push)

      _error ->
        {:error, :cancelled, transfer}
    end
  end

  defp decode_body(encoded) when is_binary(encoded) do
    if byte_size(encoded) <= div(@max_request_bytes + 2, 3) * 4 do
      case Base.decode64(encoded) do
        {:ok, body} when byte_size(body) <= @max_request_bytes -> {:ok, body}
        _ -> {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp decode_body(_encoded), do: {:error, :invalid_request}

  defp request_headers(headers) when is_list(headers) and length(headers) <= 32 do
    Enum.reduce_while(headers, {:ok, [{"accept-encoding", "identity"}]}, fn
      [name, value], {:ok, acc}
      when is_binary(name) and is_binary(value) and byte_size(name) <= 128 and
             byte_size(value) <= 8192 ->
        name = String.downcase(name)

        cond do
          not Regex.match?(@request_header_name, name) or
              String.contains?(value, ["\r", "\n", <<0>>]) ->
            {:halt, {:error, :invalid_request}}

          name in @blocked_request_headers or String.starts_with?(name, "x-forwarded-") or
              String.starts_with?(name, "proxy-") ->
            {:cont, {:ok, acc}}

          true ->
            {:cont, {:ok, [{name, value} | acc]}}
        end

      _header, _acc ->
        {:halt, {:error, :invalid_request}}
    end)
  end

  defp request_headers(_headers), do: {:error, :invalid_request}

  defp emit_error(push, id, code) do
    push.(%{"request_id" => id, "type" => "error", "code" => Atom.to_string(code)})
  catch
    _kind, _reason -> {:error, :cancelled}
  end

  defp endpoint(endpoints, api) do
    case Map.get(endpoints, api) do
      endpoint when is_binary(endpoint) -> {:ok, endpoint}
      nil -> {:error, :unsupported_api}
    end
  end

  defp error_code(%HTTP.RequestError{reason: reason}), do: error_code(reason)
  defp error_code({:timeout, _detail}), do: :timeout
  defp error_code(reason) when reason in @timeout_reasons, do: :timeout
  defp error_code(_error), do: :upstream_error
end
