defmodule Backplane.SkillProtocol.Client do
  @moduledoc "Instance-scoped, bounded client for the Skill Protocol v1 read API."

  alias Backplane.SkillProtocol.{Bundle, Error, SkillRef, Telemetry, Wire}

  @default_json_bytes 4 * 1024 * 1024
  @default_artifact_bytes 16 * 1024 * 1024
  @default_timeout_ms 30_000

  @enforce_keys [:endpoint, :source_id, :access_context_id, :credential_supplier, :transport]
  defstruct [
    :endpoint,
    :source_id,
    :access_context_id,
    :credential_supplier,
    :transport,
    :clock,
    :sleep,
    :cancelled?,
    max_json_bytes: @default_json_bytes,
    max_artifact_bytes: @default_artifact_bytes,
    overall_timeout_ms: @default_timeout_ms,
    max_attempts: 3,
    retry_delays_ms: [100, 250]
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) do
    endpoint = Keyword.get(opts, :endpoint)
    source_id = Keyword.get(opts, :source_id)
    access_context_id = Keyword.get(opts, :access_context_id)
    supplier = Keyword.get(opts, :credential_supplier, fn -> nil end)
    transport = Keyword.get(opts, :transport, Backplane.SkillProtocol.Transport.Req)
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    with {:ok, endpoint} <- endpoint(endpoint),
         :ok <- nonempty(source_id, "source_id"),
         :ok <- nonempty(access_context_id, "access_context_id"),
         true <- is_function(supplier, 0),
         true <- is_function(transport, 1) or is_atom(transport),
         true <- is_integer(max_attempts) and max_attempts in 1..3 do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         source_id: source_id,
         access_context_id: access_context_id,
         credential_supplier: supplier,
         transport: transport,
         clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
         sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
         cancelled?: Keyword.get(opts, :cancelled?, fn -> false end),
         max_json_bytes: Keyword.get(opts, :max_json_bytes, @default_json_bytes),
         max_artifact_bytes: Keyword.get(opts, :max_artifact_bytes, @default_artifact_bytes),
         overall_timeout_ms: Keyword.get(opts, :overall_timeout_ms, @default_timeout_ms),
         max_attempts: max_attempts,
         retry_delays_ms: Keyword.get(opts, :retry_delays_ms, [100, 250])
       }}
    else
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> error(:invalid_request, "client configuration is invalid")
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, reason.message
    end
  end

  @spec catalog(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def catalog(%__MODULE__{} = client, opts \\ []) do
    started_at = Telemetry.start()

    params =
      opts
      |> Keyword.take([:limit, :cursor, :q, :tag])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> maybe_catalog_fields(opts[:fields])

    {result, response_bytes} =
      case get(client, "/skill-protocol/v1/catalog", params, client.max_json_bytes, opts) do
        {:ok, body} -> {Wire.decode_catalog(body, client.source_id), byte_size(body)}
        {:error, %Error{} = reason} -> {{:error, reason}, 0}
      end

    Telemetry.emit(:client, :catalog, result, started_at,
      metadata: %{source_id: client.source_id},
      measurements: %{request_bytes: 0, response_bytes: response_bytes}
    )
  end

  @spec resolve(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Backplane.SkillProtocol.BundleManifest.t()} | {:error, Error.t()}
  def resolve(%__MODULE__{} = client, skill_id, revision \\ nil, opts \\ []) do
    started_at = Telemetry.start()
    params = [skill_id: skill_id] ++ if(is_nil(revision), do: [], else: [revision: revision])

    {result, response_bytes} =
      case get(client, "/skill-protocol/v1/resolve", params, client.max_json_bytes, opts) do
        {:ok, body} ->
          result =
            Wire.decode_manifest(body, client.source_id,
              skill_id: skill_id,
              revision: revision,
              supported_capabilities: Keyword.get(opts, :supported_capabilities, [])
            )

          {result, byte_size(body)}

        {:error, %Error{} = reason} ->
          {{:error, reason}, 0}
      end

    Telemetry.emit(:client, :resolve, result, started_at,
      metadata: resolved_metadata(client, result, skill_id, revision),
      measurements: %{request_bytes: 0, response_bytes: response_bytes}
    )
  end

  @spec artifact(t(), SkillRef.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def artifact(client, ref, opts \\ [])

  def artifact(
        %__MODULE__{} = client,
        %SkillRef{skill_id: skill_id, revision: revision, artifact_digest: digest},
        opts
      )
      when is_binary(revision) and is_binary(digest) do
    started_at = Telemetry.start()
    params = [skill_id: skill_id, revision: revision]

    {result, response_bytes} =
      case get(client, "/skill-protocol/v1/artifact", params, client.max_artifact_bytes, opts) do
        {:ok, bytes} ->
          result =
            if Bundle.artifact_digest(bytes) == digest,
              do: {:ok, bytes},
              else: error(:integrity_mismatch, "artifact digest does not match manifest")

          {result, byte_size(bytes)}

        {:error, %Error{} = reason} ->
          {{:error, reason}, 0}
      end

    Telemetry.emit(:client, :artifact, result, started_at,
      metadata: %{
        source_id: client.source_id,
        skill_id: skill_id,
        revision: revision,
        artifact_digest: digest
      },
      measurements: %{request_bytes: 0, response_bytes: response_bytes}
    )
  end

  def artifact(%__MODULE__{}, _ref, _opts),
    do: error(:invalid_request, "artifact fetch requires an exact reference")

  defp get(client, path, params, max_bytes, opts) do
    deadline = client.clock.() + client.overall_timeout_ms
    url = build_url(client.endpoint, path, params)
    cancelled? = combine_cancellation(client.cancelled?, Keyword.get(opts, :cancelled?))
    request(%{client | cancelled?: cancelled?}, url, max_bytes, deadline, 1)
  end

  defp request(client, url, max_bytes, deadline, attempt) do
    with :ok <- available(client, deadline),
         {:ok, headers} <- headers(client),
         remaining when remaining > 0 <- deadline - client.clock.(),
         result <-
           invoke_bounded(client, %{
             url: url,
             headers: headers,
             timeout_ms: remaining,
             deadline: deadline,
             max_bytes: max_bytes,
             cancelled?: client.cancelled?
           }),
         :ok <- available(client, deadline),
         result <- normalize_result(result, max_bytes) do
      case result do
        {:ok, body} ->
          {:ok, body}

        {:error, %Error{retryable: true} = reason} ->
          retry(client, url, max_bytes, deadline, attempt, reason)

        {:error, %Error{} = reason} ->
          {:error, reason}
      end
    else
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> error(:timeout, "request deadline was exceeded", %{}, true)
    end
  end

  defp retry(client, url, max_bytes, deadline, attempt, reason)
       when attempt < client.max_attempts do
    delay = Enum.at(client.retry_delays_ms, attempt - 1, 0)
    remaining = deadline - client.clock.()

    if delay < remaining do
      with :ok <- wait_for_retry(client, deadline, delay) do
        request(client, url, max_bytes, deadline, attempt + 1)
      end
    else
      {:error, %{reason | code: :timeout, message: "request deadline was exceeded"}}
    end
  end

  defp retry(_client, _url, _max_bytes, _deadline, _attempt, reason), do: {:error, reason}

  defp wait_for_retry(client, deadline, remaining_delay) when remaining_delay > 0 do
    with :ok <- available(client, deadline) do
      case deadline - client.clock.() do
        deadline_remaining when deadline_remaining > 0 ->
          interval = Enum.min([remaining_delay, 25, deadline_remaining])
          client.sleep.(interval)
          wait_for_retry(client, deadline, remaining_delay - interval)

        _expired ->
          error(:timeout, "request deadline was exceeded")
      end
    end
  end

  defp wait_for_retry(client, deadline, 0), do: available(client, deadline)

  defp normalize_result({:ok, %{status: 200, body: body}}, max_bytes) do
    with {:ok, bytes} <- collect_body(body, max_bytes), do: {:ok, bytes}
  end

  defp normalize_result({:ok, %{status: status, body: body}}, max_bytes)
       when status in [401, 403, 404, 409, 410, 422, 429] or status in 500..599 do
    fallback = status_error(status)

    with {:ok, bytes} <- collect_body(body, max_bytes),
         {:ok, wire_error} <- Wire.decode_error(bytes) do
      {:error, %{wire_error | retryable: fallback.retryable and wire_error.retryable}}
    else
      _ -> {:error, fallback}
    end
  end

  defp normalize_result({:ok, %{status: status}}, _max_bytes) when status in 300..399,
    do: error(:invalid_request, "redirect response was refused")

  defp normalize_result({:ok, %{status: status}}, _max_bytes),
    do: error(:invalid_request, "unexpected HTTP response", %{status: status})

  defp normalize_result({:error, :cancelled}, _max_bytes),
    do: error(:cancelled, "request was cancelled")

  defp normalize_result({:error, :timeout}, _max_bytes),
    do: error(:timeout, "request deadline was exceeded")

  defp normalize_result({:error, :response_too_large}, _max_bytes),
    do: error(:limit_exceeded, "response exceeds byte limit")

  defp normalize_result({:error, _reason}, _max_bytes),
    do: error(:temporarily_unavailable, "transport request failed", %{}, true)

  defp normalize_result(_result, _max_bytes),
    do: error(:temporarily_unavailable, "transport returned an invalid result", %{}, true)

  defp collect_body(body, max_bytes) when is_binary(body) do
    if byte_size(body) <= max_bytes,
      do: {:ok, body},
      else: error(:limit_exceeded, "response exceeds byte limit")
  end

  defp collect_body(chunks, max_bytes) when is_list(chunks) do
    Enum.reduce_while(chunks, {:ok, [], 0}, fn chunk, {:ok, acc, size} ->
      if is_binary(chunk) and size + byte_size(chunk) <= max_bytes do
        {:cont, {:ok, [chunk | acc], size + byte_size(chunk)}}
      else
        {:halt, error(:limit_exceeded, "response exceeds byte limit")}
      end
    end)
    |> case do
      {:ok, parts, _size} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp collect_body(_body, _max_bytes), do: error(:invalid_request, "response body is invalid")

  defp status_error(401), do: Error.new(:unauthorized, :transport, "request is unauthorized")
  defp status_error(403), do: Error.new(:forbidden, :transport, "request is forbidden")

  defp status_error(404),
    do: Error.new(:revision_unavailable, :transport, "revision is unavailable")

  defp status_error(409),
    do: Error.new(:revision_unavailable, :transport, "revision is unavailable")

  defp status_error(410),
    do: Error.new(:revision_unavailable, :transport, "revision is unavailable")

  defp status_error(422), do: Error.new(:invalid_request, :transport, "request was rejected")

  defp status_error(429),
    do:
      Error.new(:temporarily_unavailable, :transport, "request was rate limited", retryable: true)

  defp status_error(_),
    do: Error.new(:temporarily_unavailable, :transport, "service is unavailable", retryable: true)

  defp headers(client) do
    case client.credential_supplier.() do
      nil -> {:ok, %{"accept" => "application/json, application/x-tar+gzip"}}
      {:ok, nil} -> {:ok, %{"accept" => "application/json, application/x-tar+gzip"}}
      token when is_binary(token) -> {:ok, auth_headers(token)}
      {:ok, token} when is_binary(token) -> {:ok, auth_headers(token)}
      {:error, _reason} -> error(:unauthorized, "credential supplier failed")
      _ -> error(:invalid_request, "credential supplier returned an invalid value")
    end
  rescue
    _ -> error(:unauthorized, "credential supplier failed")
  end

  defp auth_headers(token),
    do: %{
      "accept" => "application/json, application/x-tar+gzip",
      "authorization" => "Bearer " <> token
    }

  defp available(client, deadline) do
    cond do
      client.cancelled?.() -> error(:cancelled, "request was cancelled")
      client.clock.() >= deadline -> error(:timeout, "request deadline was exceeded")
      true -> :ok
    end
  end

  defp invoke(transport, request) when is_function(transport, 1), do: transport.(request)
  defp invoke(transport, request) when is_atom(transport), do: transport.request(request)

  defp invoke_bounded(client, request) do
    owner = self()
    ref = make_ref()

    {guardian, monitor} =
      spawn_monitor(fn -> operation_guardian(owner, ref, client.transport, request) end)

    await_response(guardian, monitor, ref, client, request.deadline)
  end

  defp operation_guardian(owner, ref, transport, request) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn -> send(guardian, {:transport_result, ref, invoke(transport, request)}) end,
        [:link, :monitor]
      )

    guard_operation(owner, owner_monitor, worker, worker_monitor, ref, :pending)
  end

  defp guard_operation(owner, owner_monitor, worker, worker_monitor, ref, result) do
    receive do
      {:transport_result, ^ref, transport_result} ->
        guard_operation(
          owner,
          owner_monitor,
          worker,
          worker_monitor,
          ref,
          {:result, transport_result}
        )

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        result = operation_result(result, reason)
        send(owner, {ref, result})
        await_owner_ack(owner_monitor, ref)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        terminate_worker(worker, worker_monitor)

      {:stop, ^ref} ->
        terminate_worker(worker, worker_monitor)
    end
  end

  defp await_owner_ack(owner_monitor, ref) do
    receive do
      {:ack, ^ref} -> Process.demonitor(owner_monitor, [:flush])
      {:stop, ^ref} -> Process.demonitor(owner_monitor, [:flush])
      {:DOWN, ^owner_monitor, :process, _owner, _reason} -> :ok
    end
  end

  defp terminate_worker(worker, worker_monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp operation_result({:result, result}, _reason), do: result
  defp operation_result(:pending, _reason), do: {:error, :transport_crashed}

  defp await_response(guardian, monitor, ref, client, deadline) do
    remaining = max(deadline - client.clock.(), 0)

    receive do
      {^ref, result} ->
        send(guardian, {:ack, ref})
        await_guardian(monitor, guardian, ref)
        result

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        {:error, :transport_crashed}
    after
      min(remaining, 25) ->
        cond do
          client.cancelled?.() ->
            stop_operation(guardian, monitor, ref)
            {:error, :cancelled}

          client.clock.() >= deadline ->
            stop_operation(guardian, monitor, ref)
            {:error, :timeout}

          true ->
            await_response(guardian, monitor, ref, client, deadline)
        end
    end
  end

  defp stop_operation(guardian, monitor, ref) do
    send(guardian, {:stop, ref})
    await_guardian(monitor, guardian, ref)
  end

  defp await_guardian(monitor, guardian, ref) do
    receive do
      {:DOWN, ^monitor, :process, ^guardian, _reason} -> flush_operation_reply(ref)
    end
  end

  defp flush_operation_reply(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp combine_cancellation(client_cancelled?, nil), do: client_cancelled?

  defp combine_cancellation(client_cancelled?, call_cancelled?)
       when is_function(call_cancelled?, 0) do
    fn -> client_cancelled?.() or call_cancelled?.() end
  end

  defp combine_cancellation(client_cancelled?, _), do: client_cancelled?

  defp build_url(endpoint, path, []), do: endpoint <> path
  defp build_url(endpoint, path, params), do: endpoint <> path <> "?" <> URI.encode_query(params)

  defp maybe_catalog_fields(params, fields) when fields in [[:argument_hint], "argument_hint"],
    do: Keyword.put(params, :fields, "argument_hint")

  defp maybe_catalog_fields(params, _fields), do: params

  defp resolved_metadata(client, {:ok, %{ref: ref}}, _skill_id, _revision) do
    %{
      source_id: client.source_id,
      skill_id: ref.skill_id,
      revision: ref.revision,
      artifact_digest: ref.artifact_digest
    }
  end

  defp resolved_metadata(client, _result, skill_id, revision),
    do: %{source_id: client.source_id, skill_id: skill_id, revision: revision}

  defp endpoint(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"] do
      {:ok, String.trim_trailing(value, "/")}
    else
      error(:invalid_request, "endpoint must be an HTTP origin")
    end
  end

  defp endpoint(_), do: error(:invalid_request, "endpoint must be an HTTP origin")

  defp nonempty(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty(_value, field), do: error(:invalid_request, field <> " must be a nonempty string")

  defp error(code, message, context \\ %{}, retryable \\ false),
    do: {:error, Error.new(code, :transport, message, context: context, retryable: retryable)}
end
