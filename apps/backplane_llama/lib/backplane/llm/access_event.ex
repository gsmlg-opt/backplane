defmodule Backplane.LLM.AccessEvent do
  @moduledoc false

  alias Backplane.LLM.{Provider, ProviderApi, UsageAccumulator}
  alias Backplane.Observability
  alias Backplane.Observability.{Context, Error, Event, Id}

  defstruct [
    :context,
    :event_id,
    :started_at_mono,
    :upstream_started_at_mono,
    :operation,
    :api_surface,
    :http_method,
    :path,
    :requested_model,
    :resolved_model,
    :provider,
    :provider_api,
    :provider_model_id,
    :provider_model_surface_id,
    :stream?,
    :request_bytes,
    :client_ip,
    :client_id,
    :usage_acc,
    :attempt_count
  ]

  @type t :: %__MODULE__{}

  @doc "Starts a root LLM proxy access lifecycle from the incoming connection."
  @spec start(Plug.Conn.t(), String.t(), atom()) :: t()
  def start(%Plug.Conn{} = conn, operation, api_surface) do
    context = Context.get(conn) || build_fallback_context(conn)
    raw_body = conn.assigns[:raw_body] || ""

    %__MODULE__{
      context: context,
      event_id: Id.generator().event_id(),
      started_at_mono: System.monotonic_time(:millisecond),
      operation: operation,
      api_surface: to_string(api_surface),
      http_method: conn.method,
      path: conn.request_path,
      client_ip: client_ip(conn),
      client_id: client_id(conn),
      request_bytes: byte_size(raw_body),
      attempt_count: 1
    }
  end

  defp client_id(%Plug.Conn{assigns: %{resource_auth: %{client_id: client_id}}}) do
    client_id
  end

  defp client_id(%Plug.Conn{assigns: assigns}), do: assigns[:client_id]

  @spec put_requested_model(t(), String.t() | nil) :: t()
  def put_requested_model(%__MODULE__{} = state, model) do
    %{state | requested_model: model}
  end

  @spec put_resolution(
          t(),
          map() | Provider.t() | nil,
          String.t(),
          ProviderApi.t() | nil,
          keyword()
        ) :: t()
  def put_resolution(%__MODULE__{} = state, provider, resolved_model, provider_api, opts \\ [])
      when is_binary(resolved_model) do
    %{
      state
      | provider: provider,
        resolved_model: resolved_model,
        provider_api: provider_api,
        provider_model_id: Keyword.get(opts, :provider_model_id),
        provider_model_surface_id: Keyword.get(opts, :provider_model_surface_id)
    }
  end

  @spec mark_stream(t()) :: t()
  def mark_stream(%__MODULE__{} = state) do
    protocol = accumulator_protocol(state)
    %{state | stream?: true, usage_acc: new_usage_accumulator(protocol)}
  end

  @spec prepare_response_observation(t()) :: t()
  def prepare_response_observation(%__MODULE__{usage_acc: acc} = state) when is_pid(acc),
    do: state

  def prepare_response_observation(%__MODULE__{} = state) do
    case response_accumulator_protocol(state) do
      :openai_responses ->
        %{state | usage_acc: new_usage_accumulator(:openai_responses_body)}

      protocol when protocol in [:openai_json_body, :anthropic_json_body] ->
        %{state | usage_acc: new_usage_accumulator(protocol)}

      nil ->
        state
    end
  end

  @spec response_observation?(t()) :: boolean()
  def response_observation?(%__MODULE__{usage_acc: acc}), do: is_pid(acc)

  @spec mark_upstream_start(t()) :: t()
  def mark_upstream_start(%__MODULE__{} = state) do
    %{state | upstream_started_at_mono: System.monotonic_time(:millisecond)}
  end

  @spec scan_stream_chunk(t(), binary()) :: t()
  def scan_stream_chunk(%__MODULE__{usage_acc: acc} = state, chunk) when is_pid(acc) do
    UsageAccumulator.scan_chunk(acc, chunk)
    state
  end

  def scan_stream_chunk(%__MODULE__{} = state, _chunk), do: state

  @doc "Finalizes a terminal proxy outcome and emits observability events."
  @spec finalize(t(), Plug.Conn.t(), atom(), keyword()) :: :ok
  def finalize(%__MODULE__{} = state, %Plug.Conn{} = conn, outcome, opts \\ []) do
    usage = stream_usage(state, conn, opts)
    {outcome, opts} = protocol_outcome(outcome, opts, usage)
    record = build_record(state, conn, outcome, opts, usage)
    measurements = build_measurements(state, usage)

    if Observability.llm_write?() do
      emit_v2(state, record, measurements, opts)
    else
      emit_legacy(state, conn, record, measurements)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  after
    cleanup_usage_acc(state)
  end

  defp emit_v2(%__MODULE__{} = state, record, measurements, opts) do
    error =
      case {record.outcome, Keyword.get(opts, :error_reason), Keyword.get(opts, :error)} do
        {outcome, reason, _} when outcome in ["error", "cancelled"] and not is_nil(reason) ->
          Error.normalize(reason,
            kind: record.error_kind,
            code: record.error_code,
            source: "llm_proxy"
          )

        {_, _, %{} = error} ->
          error

        _ ->
          nil
      end

    Event.emit_stop(:llm_proxy, "request", state.context,
      event_id: state.event_id,
      measurements: measurements,
      attributes: compact_record(record),
      error: error
    )
  end

  defp compact_record(record) do
    record
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp emit_legacy(%__MODULE__{} = state, conn, record, measurements) do
    provider_id =
      case state.provider do
        %Provider{id: id} -> id
        _ -> nil
      end

    if provider_id do
      :telemetry.execute(
        [:backplane, :llm, :request],
        Map.put(measurements, :latency_ms, record.duration_ms || measurements[:duration_ms] || 0),
        %{
          provider_id: provider_id,
          model: record.resolved_model || record.requested_model,
          status: record.status,
          stream: record.stream || false,
          input_tokens: record.input_tokens,
          output_tokens: record.output_tokens,
          client_ip: record.client_ip || client_ip(conn),
          error_reason: record.error_reason
        }
      )
    end
  end

  defp build_record(%__MODULE__{} = state, conn, outcome, opts, usage) do
    status = Keyword.get(opts, :status, conn.status)
    stream? = state.stream? || false
    duration_ms = duration_ms(state)
    upstream_duration_ms = upstream_duration_ms(state, duration_ms)

    %{
      event_id: state.event_id,
      request_id: state.context.request_id,
      trace_id: state.context.trace_id,
      client_id: state.client_id,
      client_ip: state.client_ip,
      operation: state.operation,
      api_surface: state.api_surface,
      http_method: state.http_method,
      path: state.path,
      provider_id: provider_id(state),
      provider_name: provider_name(state),
      provider_api_id: provider_api_id(state),
      provider_model_id: state.provider_model_id,
      provider_model_surface_id: state.provider_model_surface_id,
      requested_model: state.requested_model,
      resolved_model: state.resolved_model,
      status: status,
      outcome: outcome_string(outcome),
      error_kind: error_kind(outcome, opts),
      error_code: observation_error_code(usage, outcome, opts, status),
      error_reason: observation_error_reason(usage, error_reason(outcome, opts)),
      stream: stream?,
      duration_ms: duration_ms,
      upstream_duration_ms: upstream_duration_ms,
      ttft_ms: usage.ttft_ms,
      stream_duration_ms: usage.stream_duration_ms,
      stream_chunks: usage.stream_chunks,
      request_bytes: state.request_bytes,
      response_bytes: response_bytes(conn),
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: total_tokens(usage.input_tokens, usage.output_tokens),
      cached_tokens: usage.cached_tokens,
      reasoning_tokens: usage.reasoning_tokens,
      finish_reason: usage.finish_reason,
      provider_request_id: usage.provider_request_id,
      attempt_count: state.attempt_count || 1,
      metadata: usage.metadata
    }
  end

  defp build_measurements(%__MODULE__{} = state, usage) do
    duration_ms = duration_ms(state)

    base = %{
      duration_ms: duration_ms,
      system_time: System.system_time()
    }

    base
    |> maybe_put(:upstream_duration_ms, upstream_duration_ms(state, duration_ms))
    |> maybe_put(:ttft_ms, usage.ttft_ms)
    |> maybe_put(:stream_duration_ms, usage.stream_duration_ms)
    |> maybe_put(:stream_chunks, usage.stream_chunks)
  end

  defp stream_usage(%__MODULE__{usage_acc: acc, stream?: stream?}, conn, _opts)
       when is_pid(acc) do
    usage = UsageAccumulator.snapshot(acc, conn.status || 0)

    if stream? do
      usage
    else
      %{usage | ttft_ms: nil, stream_duration_ms: nil, stream_chunks: nil}
    end
  end

  defp stream_usage(_state, _conn, opts) do
    {input, output} = Keyword.get(opts, :tokens, {nil, nil})

    %{
      input_tokens: input,
      output_tokens: output,
      cached_tokens: Keyword.get(opts, :cached_tokens),
      reasoning_tokens: Keyword.get(opts, :reasoning_tokens),
      finish_reason: Keyword.get(opts, :finish_reason),
      provider_request_id: Keyword.get(opts, :provider_request_id),
      observation_status: :unavailable,
      protocol_terminal: :incomplete,
      error_code: nil,
      error_type: nil,
      metadata: %{observation: %{unavailable: true}},
      ttft_ms: nil,
      stream_duration_ms: nil,
      stream_chunks: nil
    }
  end

  defp shared_responses?(%__MODULE__{
         api_surface: "openai_responses",
         path: path,
         provider: %Provider{preset_key: preset}
       })
       when preset != "openai-codex" do
    not String.ends_with?(path, "/responses/compact")
  end

  defp shared_responses?(_), do: false

  defp accumulator_protocol(%__MODULE__{operation: "compact"}), do: :compact

  defp accumulator_protocol(%__MODULE__{path: path})
       when is_binary(path) and path != "/v1/responses" do
    if String.ends_with?(path, "/responses/compact"), do: :compact, else: :legacy
  end

  defp accumulator_protocol(state) do
    if shared_responses?(state), do: :openai_responses, else: :legacy
  end

  defp response_accumulator_protocol(state) do
    cond do
      shared_responses?(state) -> :openai_responses
      state.api_surface in ["openai_chat_completions", "openai"] -> :openai_json_body
      state.api_surface == "anthropic_messages" -> :anthropic_json_body
      true -> nil
    end
  end

  defp new_usage_accumulator(protocol) do
    factory =
      Application.get_env(
        :backplane_llama,
        :usage_accumulator_factory,
        &UsageAccumulator.new/1
      )

    case factory.(protocol) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp protocol_outcome(:success, opts, %{protocol_terminal: :failed} = usage) do
    {:error,
     opts
     |> Keyword.put_new(:error_kind, "upstream_error")
     |> Keyword.put_new(:error_code, usage.error_code || "responses_failed")
     |> Keyword.put_new(:error_reason, usage.error_type || "responses_failed")}
  end

  defp protocol_outcome(outcome, opts, _usage), do: {outcome, opts}

  defp observation_error_code(usage, outcome, opts, status) do
    fallback = error_code(outcome, opts, status)

    explicit_error? =
      outcome == :cancelled or
        Enum.any?([:error_kind, :error_code, :error_reason], &Keyword.has_key?(opts, &1))

    if explicit_error?, do: fallback, else: usage.error_code || fallback
  end

  defp observation_error_reason(%{error_type: type}, nil) when is_binary(type), do: type
  defp observation_error_reason(_, fallback), do: fallback

  defp build_fallback_context(conn) do
    request_id =
      conn.assigns[:request_id] ||
        conn |> Plug.Conn.get_req_header("x-request-id") |> List.first() ||
        Id.request_id()

    Context.root(request_id: request_id)
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp duration_ms(%__MODULE__{started_at_mono: start_ms}) when is_integer(start_ms) do
    System.monotonic_time(:millisecond) - start_ms
  end

  defp duration_ms(_), do: nil

  defp upstream_duration_ms(%__MODULE__{upstream_started_at_mono: start_ms}, _duration_ms)
       when is_integer(start_ms) do
    System.monotonic_time(:millisecond) - start_ms
  end

  defp upstream_duration_ms(_state, duration_ms), do: duration_ms

  defp provider_id(%{provider: %Provider{id: id}}), do: id
  defp provider_id(_), do: nil

  defp provider_name(%{provider: %Provider{name: name}}), do: name
  defp provider_name(_), do: nil

  defp provider_api_id(%{provider_api: %ProviderApi{id: id}}), do: id
  defp provider_api_id(_), do: nil

  defp response_bytes(%Plug.Conn{resp_body: body}) when is_binary(body), do: byte_size(body)
  defp response_bytes(_), do: nil

  defp total_tokens(input, output) when is_integer(input) and is_integer(output),
    do: input + output

  defp total_tokens(_, _), do: nil

  defp outcome_string(:success), do: "success"
  defp outcome_string(:error), do: "error"
  defp outcome_string(:cancelled), do: "cancelled"
  defp outcome_string(other) when is_binary(other), do: other
  defp outcome_string(other), do: to_string(other)

  defp error_kind(:success, _opts), do: nil
  defp error_kind(:cancelled, _opts), do: "client_disconnect"
  defp error_kind(_, opts), do: to_string(Keyword.get(opts, :error_kind, "internal"))

  defp error_code(:success, _opts, _status), do: nil
  defp error_code(:cancelled, _opts, _status), do: "client_disconnect"

  defp error_code(_, opts, status) do
    case Keyword.get(opts, :error_code) do
      nil -> if is_integer(status), do: to_string(status), else: nil
      code -> to_string(code)
    end
  end

  defp error_reason(:success, _opts), do: nil

  defp error_reason(_, opts) do
    case Keyword.get(opts, :error_reason) do
      nil -> nil
      reason when is_binary(reason) -> reason
      reason -> inspect(reason)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cleanup_usage_acc(%__MODULE__{usage_acc: acc}) when is_pid(acc) do
    UsageAccumulator.stop(acc)
  end

  defp cleanup_usage_acc(_), do: :ok
end
