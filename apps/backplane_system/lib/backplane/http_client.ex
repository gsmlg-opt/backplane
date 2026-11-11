defmodule Backplane.HTTPClient do
  @moduledoc """
  Buffered and collected HTTP requests on top of `HTTP.fetch/2`.

  This is the shared outbound HTTP client for Backplane apps. It keeps the
  request vocabulary the code base used with Req so call sites stay small:

    * `:method` (default `:get`), `:url`, `:base_url`, `:params`
    * `:headers` (list or map), `:auth` (`{:bearer, token}`, `{:basic, userinfo}`
      or a raw header value), `:user_agent`
    * exactly one of `:json`, `:form` or `:body`
    * `:receive_timeout` (total request deadline, default 15 s) and
      `:connect_options` (`:timeout`, `:proxy`, `:proxy_headers`)
    * `:proxy` — an explicit `{scheme, host, port, opts}` tuple, or `:env` to
      resolve `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY` (see `Proxy`)
    * `:redirect` (default `true`), `:decode_body` (default `true`), `:raw`
    * `:retry` (`:safe_transient` default, `:transient`, `false`, or
      `fun(response_or_error) -> boolean`), `:max_retries` (default 3) and
      `:retry_delay` (integer ms or `fun(attempt) -> ms`)
    * `:into` — `fun({:data, chunk}, acc) -> {:cont, acc} | {:halt, acc}` with
      `:into_acc`, or any `Collectable`; the response body becomes the result
    * `:max_body_bytes` — reject larger response bodies
    * `:inet6` — prefer IPv6 with IPv4 fallback (Req/Mint semantics)
    * `:http1_reuse` — HTTP/1 keep-alive (default `true`, like Req's Finch pool)
    * `:adapter` — an `HTTP.Adapter` selection (tests use `{HTTP.Test, name}`)

  JSON responses (`application/json` or `+json`) are decoded unless
  `decode_body: false` or `raw: true`. Response headers are lowercase names
  mapped to value lists.
  """

  require Logger

  alias Backplane.HTTPClient.Error
  alias Backplane.HTTPClient.Proxy
  alias Backplane.HTTPClient.Response

  @default_timeout 15_000
  @default_connect_timeout 30_000
  @default_user_agent "backplane"
  @safe_methods ["GET", "HEAD"]
  @idempotent_methods ["GET", "HEAD", "OPTIONS", "PUT", "DELETE", "TRACE"]
  @transient_statuses [408, 429, 500, 502, 503, 504]
  @transient_reasons [
    :timeout,
    :connect_timeout,
    :read_idle_timeout,
    :econnrefused,
    :econnreset,
    :closed
  ]

  @type result :: {:ok, Response.t()} | {:error, Error.t()}

  @spec request(keyword()) :: result()
  def request(opts) when is_list(opts) do
    with {:ok, prepared} <- prepare(opts) do
      run(prepared, 0)
    end
  end

  @spec request!(keyword()) :: Response.t()
  def request!(opts), do: bang(request(opts))

  for method <- [:get, :post, :put, :patch, :delete, :head] do
    @spec unquote(method)(String.t() | URI.t() | keyword(), keyword()) :: result()
    def unquote(method)(url_or_opts, opts \\ [])

    def unquote(method)(opts, []) when is_list(opts),
      do: request(Keyword.put(opts, :method, unquote(method)))

    def unquote(method)(url, opts),
      do: request(opts |> Keyword.put(:url, url) |> Keyword.put(:method, unquote(method)))

    @spec unquote(:"#{method}!")(String.t() | URI.t() | keyword(), keyword()) :: Response.t()
    def unquote(:"#{method}!")(url_or_opts, opts \\ []),
      do: bang(unquote(method)(url_or_opts, opts))
  end

  defp bang({:ok, response}), do: response
  defp bang({:error, error}), do: raise(error)

  # -- preparation -----------------------------------------------------------

  defp prepare(opts) do
    method = opts |> Keyword.get(:method, :get) |> method_name()

    with {:ok, url} <- build_url(opts),
         {:ok, body, content_type} <- encode_body(opts) do
      timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

      {:ok,
       %{
         method: method,
         url: url,
         headers: build_headers(opts, content_type),
         body: body,
         timeout: timeout,
         fetch: fetch_options(opts, method, timeout, url),
         decode?: Keyword.get(opts, :decode_body, true) and not Keyword.get(opts, :raw, false),
         into: Keyword.get(opts, :into),
         into_acc: Keyword.get(opts, :into_acc),
         max_body_bytes: Keyword.get(opts, :max_body_bytes),
         retry: Keyword.get(opts, :retry, :safe_transient),
         max_retries: Keyword.get(opts, :max_retries, 3),
         retry_delay: Keyword.get(opts, :retry_delay),
         retry_log_level: Keyword.get(opts, :retry_log_level, :warning)
       }}
    end
  end

  defp method_name(method) when is_atom(method), do: method |> Atom.to_string() |> method_name()
  defp method_name(method) when is_binary(method), do: String.upcase(method)

  defp build_url(opts) do
    with {:ok, url} <- fetch_url(opts) do
      url = join_base_url(Keyword.get(opts, :base_url), url)

      case Keyword.get(opts, :params) do
        params when params in [nil, []] or params == %{} -> {:ok, url}
        params -> {:ok, put_params(url, params)}
      end
    end
  end

  defp fetch_url(opts) do
    case {Keyword.get(opts, :url), Keyword.get(opts, :base_url)} do
      {%URI{} = uri, _base} -> {:ok, URI.to_string(uri)}
      {url, _base} when is_binary(url) -> {:ok, url}
      {nil, base} when is_binary(base) or is_struct(base, URI) -> {:ok, ""}
      _ -> {:error, Error.exception(reason: :invalid_url)}
    end
  end

  defp join_base_url(nil, url), do: url
  defp join_base_url(%URI{} = base, url), do: join_base_url(URI.to_string(base), url)

  defp join_base_url(base, url) do
    if String.contains?(url, "://") do
      url
    else
      case url do
        "" -> base
        url -> String.trim_trailing(base, "/") <> "/" <> String.trim_leading(url, "/")
      end
    end
  end

  defp put_params(url, params) do
    uri = URI.parse(url)
    encoded = URI.encode_query(params)
    query = if uri.query in [nil, ""], do: encoded, else: uri.query <> "&" <> encoded
    URI.to_string(%{uri | query: query})
  end

  defp encode_body(opts) do
    case {Keyword.fetch(opts, :json), Keyword.fetch(opts, :form), Keyword.fetch(opts, :body)} do
      {{:ok, json}, :error, :error} -> {:ok, Jason.encode_to_iodata!(json), "application/json"}
      {:error, {:ok, form}, :error} -> {:ok, URI.encode_query(form), form_content_type()}
      {:error, :error, {:ok, body}} -> {:ok, body, nil}
      {:error, :error, :error} -> {:ok, nil, nil}
      _ -> {:error, Error.exception(reason: :conflicting_body_options)}
    end
  end

  defp form_content_type, do: "application/x-www-form-urlencoded"

  defp build_headers(opts, content_type) do
    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {name, value} -> {header_name(name), header_value(value)} end)

    headers
    |> put_new_header("user-agent", Keyword.get(opts, :user_agent, @default_user_agent))
    |> put_new_header("content-type", content_type)
    |> put_new_header("accept", if(Keyword.has_key?(opts, :json), do: "application/json"))
    |> put_auth(Keyword.get(opts, :auth))
  end

  defp header_name(name), do: name |> to_string() |> String.downcase()
  defp header_value(value) when is_binary(value), do: value
  defp header_value(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp header_value(value), do: to_string(value)

  defp put_new_header(headers, _name, nil), do: headers

  defp put_new_header(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value}]
  end

  defp put_auth(headers, nil), do: headers

  defp put_auth(headers, {:bearer, token}),
    do: List.keystore(headers, "authorization", 0, {"authorization", "Bearer " <> token})

  defp put_auth(headers, {:basic, userinfo}),
    do:
      List.keystore(
        headers,
        "authorization",
        0,
        {"authorization", "Basic " <> Base.encode64(userinfo)}
      )

  defp put_auth(headers, value) when is_binary(value),
    do: List.keystore(headers, "authorization", 0, {"authorization", value})

  defp fetch_options(opts, method, timeout, url) do
    connect = Keyword.get(opts, :connect_options, [])
    connect_timeout = Keyword.get(connect, :timeout, @default_connect_timeout)

    [
      method: method,
      timeout: timeout,
      connect_timeout: min_timeout(connect_timeout, timeout),
      redirect: if(Keyword.get(opts, :redirect, true), do: :follow, else: :manual),
      error_mode: :structured,
      http1_reuse: Keyword.get(opts, :http1_reuse, true)
    ]
    |> put_proxy(opts, connect, url)
    |> put_if(:adapter, Keyword.get(opts, :adapter))
    |> put_if(:prefer_ipv6, if(Keyword.get(opts, :inet6, false), do: true))
  end

  defp min_timeout(:infinity, timeout), do: timeout
  defp min_timeout(connect, :infinity), do: connect
  defp min_timeout(connect, timeout), do: min(connect, timeout)

  defp put_proxy(fetch, opts, connect, url) do
    case Keyword.get(opts, :proxy) || Keyword.get(connect, :proxy) do
      nil ->
        fetch

      :env ->
        put_if(fetch, :proxy, Proxy.from_env(url))

      {scheme, host, port, proxy_opts} ->
        Keyword.put(fetch, :proxy, {scheme, host, port, proxy_options(proxy_opts, connect)})
    end
  end

  # http_fetch accepts proxy :headers, :timeout and :ssl. Mint-style tuples carry
  # the connect timeout in :transport_opts and CONNECT headers in :proxy_headers.
  defp proxy_options(proxy_opts, connect) do
    headers = Keyword.get(proxy_opts, :headers, []) ++ Keyword.get(connect, :proxy_headers, [])

    timeout =
      Keyword.get(proxy_opts, :timeout) ||
        get_in(proxy_opts, [:transport_opts, :timeout]) ||
        Keyword.get(proxy_opts, :tunnel_timeout)

    [headers: headers, timeout: timeout, ssl: Keyword.get(proxy_opts, :ssl)]
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # -- execution -------------------------------------------------------------

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(upstream): gsmlg-dev/http_fetch#160
  # WORKAROUND(upstream): gsmlg-dev/http_fetch#160
  # HTTP.fetch/2 performs one attempt, so Req's transient-retry behavior is
  # reproduced here. Remove this loop once http_fetch ships an opt-in retry policy.
  defp run(prepared, attempt) do
    result = attempt(prepared)

    if retry?(prepared, result, attempt) do
      delay = retry_delay(prepared, result, attempt)
      log_retry(prepared, result, attempt, delay)
      Process.sleep(delay)
      run(prepared, attempt + 1)
    else
      result
    end
  end

  defp attempt(prepared) do
    fetch =
      prepared.fetch
      |> Keyword.put(:headers, prepared.headers)
      |> put_if(:body, prepared.body && IO.iodata_to_binary(prepared.body))
      |> maybe_stream(prepared)

    prepared.url
    |> HTTP.fetch(fetch)
    |> HTTP.Promise.await(await_timeout(prepared.timeout))
    |> handle_response(prepared)
  catch
    :exit, reason -> {:error, Error.exception(reason: exit_reason(reason))}
  end

  defp maybe_stream(fetch, %{into: nil, max_body_bytes: nil}), do: fetch
  defp maybe_stream(fetch, _prepared), do: Keyword.put(fetch, :stream_response, true)

  defp await_timeout(:infinity), do: :infinity
  defp await_timeout(timeout), do: timeout + 5_000

  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(reason), do: reason

  defp handle_response(%HTTP.Response{} = response, prepared) do
    headers = response_headers(response)

    with {:ok, body} <- read_body(response, prepared),
         {:ok, body} <- decode(body, headers, prepared) do
      {:ok, %Response{status: response.status, headers: headers, body: body}}
    end
  end

  defp handle_response({:error, reason}, _prepared),
    do: {:error, Error.exception(reason: normalize_reason(reason))}

  defp handle_response(other, _prepared),
    do: {:error, Error.exception(reason: normalize_reason(other))}

  defp response_headers(%HTTP.Response{headers: %HTTP.Headers{headers: headers}}) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      Map.update(acc, name, [to_string(value)], &(&1 ++ [to_string(value)]))
    end)
  end

  defp read_body(response, %{into: nil, max_body_bytes: nil}),
    do: {:ok, HTTP.Response.read_all(response)}

  defp read_body(response, prepared) do
    case HTTP.Response.stream_pid(response) do
      pid when is_pid(pid) -> consume_stream(pid, prepared)
      nil -> consume_binary(response.body || "", prepared)
    end
  rescue
    error in RuntimeError -> {:error, Error.exception(reason: {:stream, error.message})}
  end

  defp consume_binary(body, prepared) do
    collector = collector(prepared)

    with :ok <- check_size(byte_size(body), prepared) do
      case collector.step.(body, collector.acc) do
        {:cont, acc} -> {:ok, collector.done.(acc)}
        {:halt, acc} -> {:ok, collector.done.(acc)}
      end
    end
  end

  defp consume_stream(pid, prepared) do
    monitor = Process.monitor(pid)
    send(pid, {:read_chunk, self(), :ack})
    deadline = deadline(prepared.timeout)

    try do
      collector = collector(prepared)
      stream_loop(pid, monitor, deadline, prepared, collector, collector.acc, 0)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp stream_loop(pid, monitor, deadline, prepared, collector, acc, size) do
    receive do
      {:stream_chunk, ^pid, chunk, ack_ref} ->
        send(pid, {:stream_chunk_ack, ack_ref})
        stream_chunk(pid, monitor, deadline, prepared, collector, acc, size, chunk)

      {:stream_chunk, ^pid, chunk} ->
        stream_chunk(pid, monitor, deadline, prepared, collector, acc, size, chunk)

      {:stream_end, ^pid} ->
        {:ok, collector.done.(acc)}

      {:stream_error, ^pid, reason} ->
        collector.abort.(acc)
        {:error, Error.exception(reason: normalize_reason(reason))}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        collector.abort.(acc)
        {:error, Error.exception(reason: {:stream_down, reason})}
    after
      remaining(deadline) ->
        HTTP.Stream.stop(pid, :timeout)
        collector.abort.(acc)
        {:error, Error.exception(reason: :timeout)}
    end
  end

  defp stream_chunk(pid, monitor, deadline, prepared, collector, acc, size, chunk) do
    size = size + byte_size(chunk)

    case check_size(size, prepared) do
      :ok ->
        case collector.step.(chunk, acc) do
          {:cont, acc} ->
            stream_loop(pid, monitor, deadline, prepared, collector, acc, size)

          {:halt, acc} ->
            HTTP.Stream.stop(pid, :cancelled)
            {:ok, collector.done.(acc)}
        end

      {:error, _} = error ->
        HTTP.Stream.stop(pid, :too_large)
        collector.abort.(acc)
        error
    end
  end

  defp check_size(_size, %{max_body_bytes: nil}), do: :ok
  defp check_size(size, %{max_body_bytes: max}) when size <= max, do: :ok
  defp check_size(_size, _prepared), do: {:error, Error.exception(reason: :response_too_large)}

  defp collector(%{into: nil}) do
    %{
      acc: [],
      step: fn chunk, acc -> {:cont, [acc, chunk]} end,
      done: &IO.iodata_to_binary/1,
      abort: fn _ -> :ok end
    }
  end

  defp collector(%{into: fun, into_acc: initial}) when is_function(fun, 2) do
    %{
      acc: initial,
      step: fn chunk, acc -> fun.({:data, chunk}, acc) end,
      done: & &1,
      abort: fn _ -> :ok end
    }
  end

  defp collector(%{into: collectable}) do
    {initial, collect} = Collectable.into(collectable)

    %{
      acc: initial,
      step: fn chunk, acc -> {:cont, collect.(acc, {:cont, chunk})} end,
      done: fn acc -> collect.(acc, :done) end,
      abort: fn acc -> collect.(acc, :halt) end
    }
  end

  defp decode(body, headers, %{decode?: true, into: nil}) when is_binary(body) and body != "" do
    if json_content?(headers) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, error} -> {:error, Error.exception(reason: {:invalid_json, error})}
      end
    else
      {:ok, body}
    end
  end

  defp decode(body, _headers, _prepared), do: {:ok, body}

  defp json_content?(headers) do
    case Map.get(headers, "content-type", []) do
      [type | _] ->
        mime = type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
        mime == "application/json" or String.ends_with?(mime, "+json")

      [] ->
        false
    end
  end

  defp normalize_reason(%HTTP.RequestError{reason: reason}), do: normalize_reason(reason)
  defp normalize_reason({:timeout, _}), do: :timeout
  defp normalize_reason({:connect_failed, reason}), do: normalize_reason(reason)
  defp normalize_reason({:connect_failure, _token, reason}), do: normalize_reason(reason)
  defp normalize_reason(reason), do: reason

  # -- retry -----------------------------------------------------------------

  defp retry?(%{max_retries: max}, _result, attempt) when attempt >= max, do: false
  defp retry?(%{retry: false}, _result, _attempt), do: false
  defp retry?(%{retry: fun}, result, _attempt) when is_function(fun, 1), do: fun.(unwrap(result))

  defp retry?(%{retry: :safe_transient, method: method}, result, _attempt),
    do: method in @safe_methods and transient?(result)

  defp retry?(%{retry: :transient, method: method}, result, _attempt),
    do: method in @idempotent_methods and transient?(result)

  defp retry?(_prepared, _result, _attempt), do: false

  defp unwrap({:ok, response}), do: response
  defp unwrap({:error, error}), do: error

  defp transient?({:ok, %Response{status: status}}), do: status in @transient_statuses
  defp transient?({:error, %Error{reason: reason}}), do: reason in @transient_reasons

  defp retry_delay(%{retry_delay: delay}, _result, _attempt) when is_integer(delay), do: delay

  defp retry_delay(%{retry_delay: fun}, _result, attempt) when is_function(fun, 1),
    do: fun.(attempt)

  defp retry_delay(_prepared, {:ok, %Response{} = response}, attempt) do
    case retry_after(response) do
      nil -> backoff(attempt)
      delay -> delay
    end
  end

  defp retry_delay(_prepared, _result, attempt), do: backoff(attempt)

  defp backoff(attempt), do: Integer.pow(2, attempt) * 1_000

  defp retry_after(response) do
    with [value | _] <- Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      max(seconds, 0) * 1_000
    else
      _ -> nil
    end
  end

  defp log_retry(%{retry_log_level: false}, _result, _attempt, _delay), do: :ok

  defp log_retry(prepared, result, attempt, delay) do
    Logger.log(
      prepared.retry_log_level,
      "HTTP #{prepared.method} retry #{attempt + 1}/#{prepared.max_retries} in #{delay}ms: " <>
        retry_reason(result)
    )
  end

  defp retry_reason({:ok, %Response{status: status}}), do: "status #{status}"
  defp retry_reason({:error, %Error{reason: reason}}), do: inspect(reason)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
