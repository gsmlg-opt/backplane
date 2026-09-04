defmodule Backplane.MCP.AccessEvent do
  @moduledoc false

  require Logger

  alias Backplane.Observability
  alias Backplane.Observability.{Context, Error, Event, Id}

  defstruct [
    :context,
    :event_id,
    :started_at_mono,
    :operation,
    :transport,
    :request_bytes,
    :runtime_only?
  ]

  @type t :: %__MODULE__{}

  @doc "Starts a root MCP proxy access lifecycle from the incoming connection."
  @spec start(Plug.Conn.t()) :: t()
  def start(%Plug.Conn{} = conn) do
    context = Context.get(conn) || build_fallback_context(conn)
    raw_body = conn.assigns[:raw_body] || ""

    %__MODULE__{
      context: context,
      event_id: Id.generator().event_id(),
      started_at_mono: System.monotonic_time(:millisecond),
      operation: operation_for(conn),
      transport: "streamable_http",
      request_bytes: byte_size(raw_body),
      runtime_only?: runtime_only?(conn)
    }
  end

  @doc "Finalizes a terminal MCP proxy outcome and emits observability events."
  @spec finalize(t(), Plug.Conn.t(), atom(), keyword()) :: :ok
  def finalize(%__MODULE__{} = state, %Plug.Conn{} = conn, outcome, opts \\ []) do
    record = build_record(state, conn, outcome, opts)
    measurements = %{duration_ms: record.duration_ms, system_time: System.system_time()}

    cond do
      Observability.mcp_write?() and not state.runtime_only? ->
        emit_v2(state, record, measurements, conn, outcome, opts)

      Observability.enabled?() and state.runtime_only? ->
        emit_runtime_only(state, record, measurements)

      Observability.enabled?() ->
        emit_runtime_only(state, record, measurements)

      true ->
        emit_legacy(state, conn, record, measurements)
    end

    :ok
  end

  defp emit_v2(%__MODULE__{} = state, record, measurements, conn, outcome, opts) do
    error = build_error(record, conn, outcome, opts)

    Event.emit_stop(:mcp_proxy, "request", state.context,
      event_id: state.event_id,
      measurements: measurements,
      attributes: compact_record(record),
      error: error
    )
  end

  defp emit_runtime_only(%__MODULE__{} = state, record, measurements) do
    if Observability.runtime_sink?() do
      :telemetry.execute(
        [:backplane, :mcp_request, :start],
        measurements,
        %{
          method: state.operation,
          request_id: state.context.request_id,
          runtime_only: true,
          http_method: record.http_method,
          path: record.path
        }
      )
    end

    :ok
  end

  defp emit_legacy(%__MODULE__{} = _state, _conn, record, _measurements) do
    duration_us = (record.duration_ms || 0) * 1_000
    level = if record.http_status && record.http_status >= 500, do: :error, else: :info

    metadata =
      [
        method: record.http_method,
        path: record.path,
        status: record.http_status,
        duration_us: duration_us,
        remote_ip: record.remote_ip
      ]
      |> maybe_put_rpc_method(record.rpc_method)

    Logger.log(level, fn -> legacy_log_message(record, duration_us) end, metadata)
    :ok
  end

  defp build_record(%__MODULE__{} = state, conn, outcome, opts) do
    status = Keyword.get(opts, :status, conn.status)
    duration_ms = duration_ms(state)
    jsonrpc_error_code = Keyword.get(opts, :jsonrpc_error_code, extract_jsonrpc_error_code(conn))

    %{
      event_id: state.event_id,
      request_id: state.context.request_id,
      trace_id: state.context.trace_id,
      operation: state.operation,
      rpc_id: rpc_id(conn),
      rpc_method: rpc_method(conn),
      protocol_version: protocol_version(conn),
      era: era(conn),
      transport: state.transport,
      session_id: session_id(conn),
      client_id: client_id(conn),
      client_name: client_name(conn),
      client_version: client_version(conn),
      auth_kind: auth_kind(conn),
      remote_ip: remote_ip(conn),
      http_method: conn.method,
      path: conn.request_path,
      http_status: status,
      jsonrpc_error_code: jsonrpc_error_code,
      request_bytes: state.request_bytes,
      response_bytes: response_bytes(conn),
      duration_ms: duration_ms,
      outcome: outcome_string(outcome, status, jsonrpc_error_code),
      idempotency_status: idempotency_status(conn),
      error_kind: error_kind(outcome, status, jsonrpc_error_code, opts),
      error_code: error_code(outcome, status, jsonrpc_error_code, opts),
      error_message: error_message(outcome, opts),
      metadata: %{}
    }
  end

  defp build_error(record, conn, _outcome, opts) do
    if record.outcome == "success" do
      nil
    else
      Error.normalize(
        Keyword.get(opts, :error_reason, conn.resp_body || "request failed"),
        kind: record.error_kind,
        code: record.error_code,
        source: "mcp_proxy"
      )
    end
  end

  defp compact_record(record) do
    record
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp operation_for(%Plug.Conn{method: "HEAD"}), do: "health_probe"
  defp operation_for(%Plug.Conn{method: "DELETE"}), do: "session_delete"
  defp operation_for(%Plug.Conn{method: "GET"}), do: "sse_open"
  defp operation_for(%Plug.Conn{method: "POST"}), do: "jsonrpc"
  defp operation_for(%Plug.Conn{method: method}), do: to_string(method)

  defp runtime_only?(%Plug.Conn{method: "HEAD"}), do: true
  defp runtime_only?(_), do: false

  defp build_fallback_context(conn) do
    request_id =
      conn.assigns[:request_id] ||
        conn |> Plug.Conn.get_req_header("x-request-id") |> List.first() ||
        Id.request_id()

    Context.root(request_id: request_id)
  end

  defp rpc_method(conn) do
    case body_params(conn) do
      %{"method" => method} when is_binary(method) -> method
      %{"_json" => [%{"method" => method} | _]} when is_binary(method) -> method
      _ -> nil
    end
  end

  defp rpc_id(conn) do
    id =
      case body_params(conn) do
        %{"id" => value} -> value
        %{"_json" => [%{"id" => value} | _]} -> value
        _ -> nil
      end

    case id do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp protocol_version(conn) do
    conn.assigns[:mcp_protocol_version] ||
      conn
      |> Plug.Conn.get_req_header("mcp-protocol-version")
      |> List.first()
  end

  defp era(conn) do
    case conn.assigns[:mcp_era] do
      value when value in [:legacy, :modern] -> Atom.to_string(value)
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp session_id(conn) do
    conn.assigns[:mcp_session_id] ||
      conn
      |> Plug.Conn.get_req_header("mcp-session-id")
      |> List.first()
  end

  defp client_id(conn) do
    case conn.assigns[:client] do
      %{id: id} -> id
      _ -> get_in(conn.assigns, [:resource_auth, :client_id])
    end
  end

  defp client_name(conn) do
    case get_in(body_params(conn), ["params", "clientInfo", "name"]) do
      name when is_binary(name) ->
        name

      _ ->
        case conn.assigns[:client] do
          %{name: name} when is_binary(name) -> name
          _ -> nil
        end
    end
  end

  defp client_version(conn) do
    case get_in(body_params(conn), ["params", "clientInfo", "version"]) do
      version when is_binary(version) -> version
      _ -> nil
    end
  end

  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}

  defp body_params(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp body_params(_), do: %{}

  defp auth_kind(conn) do
    case get_in(conn.assigns, [:resource_auth, :kind]) do
      kind when kind in [:oauth, :client_token, :legacy, :open] -> Atom.to_string(kind)
      kind when is_binary(kind) -> kind
      _ -> nil
    end
  end

  defp remote_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip
      [] -> format_ip(conn.remote_ip)
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  defp idempotency_status(conn) do
    case conn.assigns[:mcp_idempotency_status] do
      status when status in ["hit", "miss", "bypass"] -> status
      _ -> if idempotency_key?(conn), do: "miss", else: nil
    end
  end

  defp idempotency_key?(conn) do
    conn
    |> Plug.Conn.get_req_header("idempotency-key")
    |> case do
      [key | _] when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  defp extract_jsonrpc_error_code(conn) do
    with true <- is_binary(conn.resp_body),
         {:ok, decoded} <- Jason.decode(conn.resp_body),
         code when is_integer(code) <- jsonrpc_error_from(decoded) do
      code
    else
      _ -> nil
    end
  end

  defp jsonrpc_error_from(%{"error" => %{"code" => code}}) when is_integer(code), do: code

  defp jsonrpc_error_from(list) when is_list(list) do
    Enum.find_value(list, fn
      %{"error" => %{"code" => code}} when is_integer(code) -> code
      _ -> nil
    end)
  end

  defp jsonrpc_error_from(_), do: nil

  defp response_bytes(%Plug.Conn{resp_body: body}) when is_binary(body), do: byte_size(body)
  defp response_bytes(%Plug.Conn{resp_body: body}) when is_list(body), do: IO.iodata_length(body)
  defp response_bytes(_), do: nil

  defp duration_ms(%__MODULE__{started_at_mono: start_ms}) when is_integer(start_ms) do
    System.monotonic_time(:millisecond) - start_ms
  end

  defp duration_ms(_), do: nil

  defp outcome_string(:success, _status, _code), do: "success"
  defp outcome_string(:error, _status, _code), do: "error"
  defp outcome_string(:cancelled, _status, _code), do: "cancelled"

  defp outcome_string(_other, status, jsonrpc_error_code) do
    cond do
      is_integer(jsonrpc_error_code) -> "error"
      is_integer(status) and status >= 400 -> "error"
      true -> "success"
    end
  end

  defp error_kind(:success, _, _, _opts), do: nil
  defp error_kind(:cancelled, _, _, _opts), do: "client_disconnect"
  defp error_kind(_, 429, _, _opts), do: "rate_limit"
  defp error_kind(_, status, _, _opts) when status in [401, 403], do: "auth"
  defp error_kind(_, 413, _, _opts), do: "validation"
  defp error_kind(_, 400, _, _opts), do: "validation"
  defp error_kind(_, _, code, _opts) when is_integer(code) and code < 0, do: "protocol"
  defp error_kind(_, _, _, opts), do: to_string(Keyword.get(opts, :error_kind, "internal"))

  defp error_code(:success, _, _, _opts), do: nil
  defp error_code(:cancelled, _, _, _opts), do: "client_disconnect"
  defp error_code(_, _, code, _opts) when is_integer(code) and code < 0, do: to_string(code)
  defp error_code(_, status, _, _opts) when is_integer(status), do: to_string(status)

  defp error_code(_, _, _, opts),
    do: Keyword.get(opts, :error_code) && to_string(Keyword.get(opts, :error_code))

  defp error_message(:success, _opts), do: nil

  defp error_message(_, opts) do
    case Keyword.get(opts, :error_message) || Keyword.get(opts, :error_reason) do
      nil -> nil
      reason when is_binary(reason) -> reason
      reason -> inspect(reason)
    end
  end

  defp legacy_log_message(record, duration_us) do
    duration_ms = Float.round(duration_us / 1_000, 2)

    case record.rpc_method do
      nil ->
        "#{record.http_method} #{record.path} - #{record.http_status} in #{duration_ms}ms"

      rpc_method ->
        "MCP #{rpc_method} - #{record.http_status} in #{duration_ms}ms"
    end
  end

  defp maybe_put_rpc_method(metadata, nil), do: metadata
  defp maybe_put_rpc_method(metadata, rpc_method), do: [{:rpc_method, rpc_method} | metadata]
end
