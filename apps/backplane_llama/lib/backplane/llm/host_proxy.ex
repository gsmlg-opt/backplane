defmodule Backplane.LLM.HostProxy do
  @moduledoc "Forwards a resolved provider request through its registered host agent."

  import Plug.Conn

  alias Backplane.HostApi.Transport
  alias Backplane.LLM.HostServices

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

        conn = if stream?, do: send_chunked(conn, status), else: %{conn | status: status}

        case ack(id) do
          :ok -> receive_body(conn, id, monitor, opts, stream?, [])
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

  defp receive_body(conn, id, monitor, opts, stream?, chunks) do
    receive do
      {:host_api_frame, ^id, {:chunk, data}} ->
        case consume(conn, data, opts, stream?, chunks) do
          {:ok, conn, chunks} ->
            case ack(id) do
              :ok -> receive_body(conn, id, monitor, opts, stream?, chunks)
              _ -> error(conn, :not_connected)
            end

          {:error, conn} ->
            conn
        end

      {:host_api_frame, ^id, :done} ->
        case ack(id) do
          :ok -> finish(conn, opts, stream?, chunks)
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

  defp consume(conn, data, _opts, false, chunks), do: {:ok, conn, [data | chunks]}

  defp consume(conn, data, opts, true, chunks) do
    observe(opts[:on_response_chunk], data)

    data
    |> map_chunks(opts[:map_response_chunk])
    |> Enum.reduce_while({:ok, conn, chunks}, fn bytes, {:ok, conn, chunks} ->
      case chunk(conn, bytes) do
        {:ok, conn} ->
          {:cont, {:ok, conn, chunks}}

        {:error, _} ->
          conn = put_private(conn, :relayixir_downstream_disconnected, true)
          {:halt, {:error, conn}}
      end
    end)
  end

  defp finish(conn, opts, true, _chunks) do
    chunks =
      if is_function(opts[:flush_response_chunks], 0),
        do: opts[:flush_response_chunks].(),
        else: []

    Enum.reduce_while(chunks, conn, fn bytes, conn ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, put_private(conn, :relayixir_downstream_disconnected, true)}
      end
    end)
  end

  defp finish(conn, opts, false, chunks) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    observe(opts[:on_response_body], body)

    body =
      if is_function(opts[:map_response_body], 1), do: opts[:map_response_body].(body), else: body

    send_resp(conn, conn.status, body)
  end

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
    forwarded = Enum.filter(conn.req_headers, fn {name, _} -> name in @request_headers end)

    (forwarded ++
       auth_headers ++ [{"content-type", "application/json"}, {"accept-encoding", "identity"}])
    |> Enum.reduce(%{}, fn {name, value}, acc -> Map.put(acc, String.downcase(name), value) end)
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
      Jason.encode!(%{
        error: %{type: "api_error", code: code, message: "Host API service request failed"}
      })
    )
    |> halt()
  end

  defp safe_reason(reason) when reason in [:timeout, "timeout"], do: :host_api_timeout
  defp safe_reason(_), do: :host_api_error
end
