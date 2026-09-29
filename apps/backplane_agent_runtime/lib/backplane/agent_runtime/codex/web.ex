defmodule Backplane.AgentRuntime.Codex.Web do
  @moduledoc "Bounded, host-authorized HTTP fetch adapter for Codex service tools."

  alias Backplane.AgentRuntime.Error

  @default_timeout 5_000
  @default_max_bytes 1_048_576
  @default_result_limit 1_048_576

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(url, opts \\ [])

  def fetch(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, uri} <- validate_url(url),
         :ok <- authorize_host(uri, Keyword.get(opts, :allowed_hosts, [])),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes, @default_max_bytes),
         {:ok, response} <- request(opts, uri, timeout, max_bytes),
         {:ok, response} <- normalize_response(response),
         :ok <- validate_response_semantics(response),
         {:ok, body} <- bounded_body(response.body, max_bytes) do
      {:ok,
       %{
         status: response.status,
         headers: response.headers,
         body: body,
         url: url,
         content_type: content_type(response.headers)
       }}
    end
  end

  def fetch(_, _), do: {:error, validation("web URL and options are required")}

  @spec search(module(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def search(adapter, query, opts \\ [])

  def search(adapter, query, opts)
      when is_atom(adapter) and is_binary(query) and query != "" and is_list(opts) do
    search_backend(adapter, :search, query, opts)
  end

  def search(_, _, _), do: {:error, validation("search adapter, query, and options are required")}

  @spec x_search(module(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def x_search(adapter, query, opts \\ [])

  def x_search(adapter, query, opts)
      when is_atom(adapter) and is_binary(query) and query != "" and is_list(opts) do
    search_backend(adapter, :x_search, query, opts)
  end

  def x_search(_, _, _),
    do: {:error, validation("x search adapter, query, and options are required")}

  defp validate_url(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) do
      {:ok, uri}
    else
      {:error,
       Error.new(:forbidden, "web URL must be an absolute http(s) URL without credentials")}
    end
  end

  defp authorize_host(_uri, :all), do: :ok

  defp authorize_host(_uri, []),
    do: {:error, Error.new(:forbidden, "web host allowlist is required")}

  defp authorize_host(uri, allowed) when is_list(allowed) do
    if uri.host in allowed,
      do: :ok,
      else: {:error, Error.new(:forbidden, "web host is not authorized")}
  end

  defp authorize_host(_, _), do: {:error, validation("allowed_hosts must be a list")}

  defp positive_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, validation("#{key} must be positive")}
  end

  defp request(opts, uri, timeout, max_bytes) do
    transport = Keyword.get(opts, :transport, Backplane.AgentRuntime.Codex.Web.Httpc)

    cond do
      is_atom(transport) and Code.ensure_loaded?(transport) and
          function_exported?(transport, :request, 3) ->
        transport.request(uri, timeout, max_bytes)

      is_atom(transport) and Code.ensure_loaded?(transport) and
          function_exported?(transport, :request, 2) ->
        transport.request(uri, timeout)

      true ->
        {:error, Error.new(:unsupported_capability, "web transport is unavailable")}
    end
  rescue
    exception ->
      {:error,
       Error.new(:transient_transport, "web request failed",
         details: %{reason: inspect(exception)}
       )}
  end

  defp normalize_response(%{status: status, headers: headers, body: body} = response)
       when is_integer(status) and status >= 100 and status <= 599 and is_list(headers) and
              is_binary(body),
       do: {:ok, %{response | headers: normalize_headers(headers)}}

  defp normalize_response(response),
    do:
      {:error,
       Error.new(:malformed_result, "web transport returned an invalid response",
         details: %{received: response}
       )}

  defp bounded_body(body, max) when is_binary(body) do
    if byte_size(body) <= max,
      do: {:ok, body},
      else: {:error, Error.new(:budget_exceeded, "web response exceeds byte limit")}
  end

  defp validate_response_semantics(%{status: status}) when status in 300..399,
    do: {:error, Error.new(:forbidden, "web redirects are not followed")}

  defp validate_response_semantics(%{headers: headers}) do
    transfer_encoding =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == "transfer-encoding", do: String.downcase(value)
      end)

    if is_binary(transfer_encoding) and String.contains?(transfer_encoding, "chunked"),
      do: {:error, Error.new(:unsupported_capability, "chunked web responses are unsupported")},
      else: :ok
  end

  defp search_backend(adapter, function, query, opts) do
    if function_exported?(adapter, function, 2) do
      case apply(adapter, function, [query, opts]) do
        {:ok, result} when is_map(result) ->
          normalize_search_result(result, opts)

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error,
           Error.new(:malformed_result, "search adapter returned an invalid result",
             details: %{received: other}
           )}
      end
    else
      {:error, Error.new(:unsupported_capability, "search backend is unavailable")}
    end
  end

  defp normalize_search_result(result, opts) do
    results = Map.get(result, :results, Map.get(result, "results"))
    limit = Keyword.get(opts, :result_limit, @default_result_limit)

    cond do
      not is_list(results) ->
        {:error, Error.new(:malformed_result, "search result must contain a results list")}

      not is_integer(limit) or limit <= 0 ->
        {:error, validation("result_limit must be positive")}

      :erlang.external_size(result) > limit ->
        {:error, Error.new(:budget_exceeded, "search result exceeds the configured bound")}

      true ->
        {:ok, result}
    end
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp content_type(headers),
    do:
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == "content-type", do: value
      end)

  defp validation(message), do: Error.new(:validation, message)

  defmodule Httpc do
    @moduledoc false

    def request(uri, timeout), do: request(uri, timeout, 1_048_576)

    def request(uri, timeout, max_bytes) do
      case connect(uri, timeout) do
        {:ok, socket} ->
          result =
            try do
              with :ok <- send_request(socket, uri),
                   {:ok, response} <- receive_response(socket, timeout, max_bytes) do
                parse_response(response)
              end
            after
              close(socket)
            end

          normalize_wire_result(result)

        {:error, reason} ->
          normalize_wire_result({:error, reason})
      end
    end

    defp normalize_wire_result({:ok, _response} = result), do: result

    defp normalize_wire_result({:error, :https_requires_verified_transport}) do
      {:error,
       Backplane.AgentRuntime.Error.new(
         :unsupported_capability,
         "HTTPS requires a host-provided verified transport"
       )}
    end

    defp normalize_wire_result({:error, :response_too_large}) do
      {:error,
       Backplane.AgentRuntime.Error.new(
         :budget_exceeded,
         "web response exceeds byte limit"
       )}
    end

    defp normalize_wire_result({:error, reason}) do
      {:error,
       Backplane.AgentRuntime.Error.new(:transient_transport, "web request failed",
         details: %{reason: reason}
       )}
    end

    defp connect(%URI{scheme: "https"}, _timeout),
      do: {:error, :https_requires_verified_transport}

    defp connect(%URI{host: host, port: port}, timeout) do
      case :gen_tcp.connect(
             String.to_charlist(host),
             port || 80,
             [:binary, active: false],
             timeout
           ) do
        {:ok, socket} -> {:ok, {:tcp, socket}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp send_request({:tcp, socket}, uri), do: :gen_tcp.send(socket, request_line(uri))

    defp request_line(uri) do
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      path = if is_binary(uri.query), do: path <> "?" <> uri.query, else: path

      "GET #{path} HTTP/1.1\r\nHost: #{uri.host}\r\nConnection: close\r\n\r\n"
    end

    defp receive_response(socket, timeout, max_bytes),
      do: receive_response(socket, timeout, max_bytes, System.monotonic_time(:millisecond), [], 0)

    defp receive_response(socket, timeout, max_bytes, started, chunks, received) do
      remaining = timeout - (System.monotonic_time(:millisecond) - started)

      if remaining <= 0 do
        {:error, :timeout}
      else
        case recv(socket, remaining) do
          {:ok, chunk} when received + byte_size(chunk) <= max_bytes + 65_536 ->
            receive_response(
              socket,
              timeout,
              max_bytes,
              started,
              [chunk | chunks],
              received + byte_size(chunk)
            )

          {:ok, _chunk} ->
            {:error, :response_too_large}

          {:error, :closed} ->
            {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defp recv({:tcp, socket}, timeout), do: :gen_tcp.recv(socket, 0, timeout)

    defp close({:tcp, socket}), do: :gen_tcp.close(socket)

    defp parse_response(response) do
      case String.split(response, "\r\n\r\n", parts: 2) do
        [head, body] ->
          case String.split(head, "\r\n") do
            [status_line | header_lines] ->
              with {:ok, status} <- parse_status(status_line) do
                {:ok,
                 %{status: status, headers: Enum.map(header_lines, &parse_header/1), body: body}}
              end

            _ ->
              {:error, :malformed_response}
          end

        _ ->
          {:error, :malformed_response}
      end
    end

    defp parse_status("HTTP/" <> rest) do
      case String.split(rest, " ", parts: 2) do
        [_version, status_and_reason] ->
          [status | _] = String.split(status_and_reason, " ", parts: 2)

          case Integer.parse(status) do
            {status, ""} when status >= 100 and status <= 599 -> {:ok, status}
            _ -> {:error, :malformed_status}
          end

        _ ->
          {:error, :malformed_status}
      end
    end

    defp parse_status(_), do: {:error, :malformed_status}

    defp parse_header(line) do
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        _ -> {line, ""}
      end
    end
  end
end
