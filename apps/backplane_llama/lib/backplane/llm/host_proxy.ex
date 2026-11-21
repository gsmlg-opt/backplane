defmodule Backplane.LLM.HostProxy do
  @moduledoc "Forwards a resolved provider request through its registered host agent."

  import Plug.Conn

  alias Backplane.HostApi.Transport
  alias Backplane.LLM.{HeaderPolicy, HostServices}

  @idle_timeout 120_000
  @hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade content-length set-cookie authorization x-api-key)
  @request_headers ~w(accept anthropic-version anthropic-beta openai-beta openai-organization openai-project x-request-id)

  def call(conn, service_id, api, auth_headers, opts) do
    body = Keyword.fetch!(opts, :body)

    if byte_size(body) > Transport.max_request_bytes() do
      error(conn, :request_too_large)
    else
      with {:ok, service, _endpoint} <- HostServices.endpoint(service_id, api),
           payload = %{
             "api" => to_string(api),
             "headers" => request_headers(conn, auth_headers),
             "body_base64" => Base.encode64(body)
           },
           {:ok, id} <- Transport.open(service.host_id, service.id, service.revision, payload) do
        monitor = Process.monitor(Transport)

        try do
          receive_headers(conn, id, monitor, opts)
        after
          Process.demonitor(monitor, [:flush])
          cancel(id)
        end
      else
        {:error, reason} -> error(conn, reason)
      end
    end
  catch
    :exit, _reason -> error(conn, :not_connected)
  end

  defp receive_headers(conn, id, monitor, opts) do
    receive do
      {:host_api_frame, ^id, {:headers, status, headers}} ->
        conn = put_headers(conn, headers)

        stream? =
          Enum.any?(
            get_resp_header(conn, "content-type"),
            &String.contains?(&1, "text/event-stream")
          )

        mapper_state =
          if stream? do
            init_host_stream_mapper(opts[:response_stream_mapper], status, conn.resp_headers)
          else
            nil
          end

        conn = if stream?, do: send_chunked(conn, status), else: %{conn | status: status}

        case ack(id) do
          :ok -> receive_body(conn, id, monitor, opts, stream?, [], mapper_state)
          _ -> error(conn, :not_connected)
        end

      {:host_api_frame, ^id, {:error, reason}} ->
        ack(id)
        error(conn, reason)

      {:host_api_error, ^id, reason} ->
        error(conn, reason)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        error(conn, :not_connected)
    after
      @idle_timeout -> error(conn, :timeout)
    end
  end

  defp receive_body(conn, id, monitor, opts, stream?, chunks, mapper_state) do
    receive do
      {:host_api_frame, ^id, {:chunk, data}} ->
        case consume(conn, data, opts, stream?, chunks, mapper_state) do
          {:ok, conn, chunks, mapper_state} ->
            case ack(id) do
              :ok -> receive_body(conn, id, monitor, opts, stream?, chunks, mapper_state)
              _ -> error(conn, :not_connected)
            end

          {:error, conn} ->
            conn
        end

      {:host_api_frame, ^id, :done} ->
        case ack(id) do
          :ok -> finish(conn, opts, stream?, chunks, mapper_state)
          _ -> error(conn, :not_connected)
        end

      {:host_api_frame, ^id, {:error, reason}} ->
        ack(id)
        _ = finish_host_stream_mapper(mapper_state, reason)
        error(conn, reason)

      {:host_api_error, ^id, reason} ->
        _ = finish_host_stream_mapper(mapper_state, reason)
        error(conn, reason)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        _ = finish_host_stream_mapper(mapper_state, :not_connected)
        error(conn, :not_connected)
    after
      @idle_timeout ->
        _ = finish_host_stream_mapper(mapper_state, :timeout)
        error(conn, :timeout)
    end
  end

  defp consume(conn, data, _opts, false, chunks, mapper_state),
    do: {:ok, conn, [data | chunks], mapper_state}

  defp consume(conn, data, opts, true, chunks, mapper_state) do
    observe(opts[:on_response_chunk], data)
    {mapped, mapper_state} = feed_host_stream_mapper(mapper_state, data, opts[:map_response_chunk])

    Enum.reduce_while(mapped, {:ok, conn, chunks, mapper_state}, fn bytes,
                                                                    {:ok, conn, chunks, state} ->
      case chunk(conn, bytes) do
        {:ok, conn} ->
          {:cont, {:ok, conn, chunks, state}}

        {:error, _} ->
          _ = finish_host_stream_mapper(state, :cancelled)
          conn = put_private(conn, :relayixir_downstream_disconnected, true)
          {:halt, {:error, conn}}
      end
    end)
  end

  defp finish(conn, opts, true, _chunks, mapper_state) do
    chunks =
      case mapper_state do
        nil ->
          if is_function(opts[:flush_response_chunks], 0),
            do: opts[:flush_response_chunks].(),
            else: []

        _ ->
          finish_host_stream_mapper(mapper_state, :eof)
      end

    Enum.reduce_while(chunks, conn, fn bytes, conn ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, put_private(conn, :relayixir_downstream_disconnected, true)}
      end
    end)
  end

  defp finish(conn, opts, false, chunks, _mapper_state) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    observe(opts[:on_response_body], body)

    body =
      if is_function(opts[:map_response_body], 1), do: opts[:map_response_body].(body), else: body

    send_resp(conn, conn.status, body)
  end

  defp init_host_stream_mapper({module, arg}, status, headers) when is_atom(module) do
    case module.init(status, headers, arg) do
      {:ok, state} -> %{module: module, state: state}
      _ -> nil
    end
  end

  defp init_host_stream_mapper(_, _status, _headers), do: nil

  defp feed_host_stream_mapper(%{module: module, state: state} = mapper, data, _legacy) do
    case module.feed(state, data) do
      {:ok, next_state, chunks} -> {List.wrap(chunks), %{mapper | state: next_state}}
      {:error, _reason, next_state, chunks} -> {List.wrap(chunks), %{mapper | state: next_state}}
    end
  end

  defp feed_host_stream_mapper(nil, data, legacy_mapper),
    do: {map_chunks(data, legacy_mapper), nil}

  defp finish_host_stream_mapper(%{module: module, state: state}, reason) do
    case module.finish(state, reason) do
      {:ok, _next_state, chunks} -> List.wrap(chunks)
      {:error, _reason, _next_state, chunks} -> List.wrap(chunks)
    end
  end

  defp finish_host_stream_mapper(nil, _reason), do: []

  defp map_chunks(data, mapper) when is_function(mapper, 1) do
    case mapper.(data) do
      nil -> []
      bytes when is_binary(bytes) -> [bytes]
      chunks when is_list(chunks) -> chunks
    end
  end

  defp map_chunks(data, _), do: [data]

  defp observe(callback, bytes) when is_function(callback, 1) do
    callback.(bytes)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe(_, _), do: :ok

  defp ack(id) do
    Transport.ack(id)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  defp cancel(id) do
    Transport.cancel(id)
  catch
    :exit, _ -> :ok
  end

  defp request_headers(conn, auth_headers) do
    nominated = HeaderPolicy.connection_nominated(conn.req_headers)

    forwarded =
      conn.req_headers
      |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)
      |> Enum.filter(fn {name, _} ->
        name in @request_headers and name not in nominated
      end)

    HeaderPolicy.merge_ordered([
      forwarded,
      auth_headers,
      [{"content-type", "application/json"}, {"accept-encoding", "identity"}]
    ])
    |> Enum.map(fn {name, value} -> [name, value] end)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn [name, value], acc ->
      name = String.downcase(name)
      if name in @hop_headers, do: acc, else: put_resp_header(acc, name, value)
    end)
  end

  defp error(%Plug.Conn{state: state} = conn, reason) when state in [:sent, :chunked] do
    conn |> put_private(:relayixir_proxy_error, safe_reason(reason)) |> halt()
  end

  defp error(conn, reason) do
    {status, code} =
      case reason do
        :request_too_large ->
          {413, "host_api_request_too_large"}

        reason when reason in [:timeout, "timeout"] ->
          {504, "host_api_timeout"}

        reason
        when reason in [:invalid_response, "invalid_response", :upstream_error, "upstream_error"] ->
          {502, "host_api_upstream_error"}

        _ ->
          {503, "host_api_unavailable"}
      end

    conn
    |> put_private(:relayixir_proxy_error, safe_reason(reason))
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Formata.JSON.encode!(%{
        error: %{type: "api_error", code: code, message: "Host API service request failed"}
      })
    )
    |> halt()
  end

  defp safe_reason(reason) when reason in [:timeout, "timeout"], do: :host_api_timeout
  defp safe_reason(_), do: :host_api_error
end
