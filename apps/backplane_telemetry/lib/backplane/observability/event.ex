defmodule Backplane.Observability.Event do
  @moduledoc false

  alias Backplane.Observability.{Context, Error, Id, Redaction}

  @schema_version 1
  @domains ~w(llm_proxy mcp_proxy memory skills host_agent system security_audit)a
  @phases ~w(start stop exception event)a

  @type envelope :: map()

  @doc "Builds a root event envelope."
  @spec new_root(atom(), String.t(), Context.t(), keyword()) :: envelope()
  def new_root(domain, operation, %Context{} = context, opts \\ []) do
    build(domain, operation, Keyword.get(opts, :phase, :event), context, opts)
  end

  @doc "Builds a child span event envelope."
  @spec new_child(atom(), String.t(), Context.t(), keyword()) :: envelope()
  def new_child(domain, operation, %Context{} = context, opts \\ []) do
    new_root(domain, operation, context, opts)
  end

  @doc "Emits a start-phase telemetry event."
  @spec emit_start(atom(), String.t(), Context.t(), keyword()) :: :ok
  def emit_start(domain, operation, context, opts \\ []) do
    emit(domain, operation, :start, context, Keyword.put(opts, :measurements, %{system_time: System.system_time()}))
  end

  @doc "Emits a stop-phase telemetry event."
  @spec emit_stop(atom(), String.t(), Context.t(), keyword()) :: :ok
  def emit_stop(domain, operation, context, opts \\ []) do
    emit(domain, operation, :stop, context, opts)
  end

  @doc "Emits an exception-phase telemetry event."
  @spec emit_exception(atom(), String.t(), Context.t(), term(), keyword()) :: :ok
  def emit_exception(domain, operation, context, reason, opts \\ []) do
    error = Error.normalize(reason, Keyword.get(opts, :error, []))

    emit(
      domain,
      operation,
      :exception,
      context,
      Keyword.merge(opts, error: error, severity: :error)
    )
  end

  @doc "Executes telemetry for a validated envelope."
  @spec emit_envelope(envelope()) :: :ok
  def emit_envelope(envelope) do
    with :ok <- validate(envelope) do
      name = telemetry_name(envelope.domain, envelope.operation, envelope.phase)

      metadata =
        envelope
        |> Map.take([:event_id, :occurred_at, :domain, :operation, :phase, :severity, :context, :attributes, :error, :payload_ref])
        |> Map.new(fn {k, v} -> {k, sanitize_metadata_value(v)} end)

      :telemetry.execute(name, envelope.measurements, metadata)
      :ok
    end
  end

  defp emit(domain, operation, phase, context, opts) do
    envelope = build(domain, operation, phase, context, opts)
    emit_envelope(envelope)
  end

  defp build(domain, operation, phase, context, opts) do
    measurements = Keyword.get(opts, :measurements, %{})
    attributes = opts |> Keyword.get(:attributes, %{}) |> Redaction.sanitize_attributes()
    severity = Keyword.get(opts, :severity, severity_for(phase))
    error = Keyword.get(opts, :error)
    gen = Id.generator()

    %{
      schema_version: @schema_version,
      event_id: Keyword.get(opts, :event_id, gen.event_id()),
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
      domain: domain,
      operation: operation,
      phase: phase,
      severity: severity,
      context: Context.to_map(context),
      measurements: measurements,
      attributes: attributes,
      error: error,
      payload_ref: Keyword.get(opts, :payload_ref)
    }
  end

  @doc "Validates domain, phase, and required envelope fields."
  @spec validate(envelope()) :: :ok | {:error, term()}
  def validate(%{} = envelope) do
    with :ok <- validate_domain(envelope.domain),
         :ok <- validate_phase(envelope.phase),
         true <- is_binary(envelope.event_id) and envelope.event_id != "",
         true <- match?(%DateTime{}, envelope.occurred_at) do
      :ok
    else
      false -> {:error, :invalid_envelope}
      other -> other
    end
  end

  defp validate_domain(domain) when domain in @domains, do: :ok
  defp validate_domain(domain), do: {:error, {:invalid_domain, domain}}

  defp validate_phase(phase) when phase in @phases, do: :ok
  defp validate_phase(phase), do: {:error, {:invalid_phase, phase}}

  defp telemetry_name(domain, operation, phase) do
    [:backplane, domain, operation_atom(operation), phase]
  end

  defp operation_atom(operation) when is_atom(operation), do: operation

  defp operation_atom(operation) when is_binary(operation) do
    String.to_existing_atom(operation)
  rescue
    ArgumentError -> String.to_atom(operation)
  end

  defp severity_for(:exception), do: :error
  defp severity_for(:stop), do: :info
  defp severity_for(:start), do: :debug
  defp severity_for(_), do: :info

  defp sanitize_metadata_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_metadata_value(value) when is_map(value), do: Redaction.sanitize_attributes(value)
  defp sanitize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_metadata_value(value), do: value
end
