defmodule Backplane.Observability.RuntimeSink do
  @moduledoc false

  use GenServer

  require Logger

  alias Backplane.Observability.Sink.JSONL
  alias Backplane.Observability.Sink.Logger, as: SinkLogger

  @handler_id "backplane-observability-runtime-sink"

  @legacy_events [
    [:backplane, :llm, :request],
    [:backplane, :mcp_request, :start],
    [:backplane, :tool_call, :stop],
    [:backplane, :tool_call, :exception],
    [:backplane, :memory, :access, :stop],
    [:backplane, :memory, :access, :exception],
    [:backplane, :memory, :event, :append],
    [:backplane, :memory, :event, :duplicate],
    [:backplane, :memory, :event, :error],
    [:backplane, :host_agent, :memory, :call, :stop],
    [:backplane, :host_agent, :memory, :call, :exception],
    [:backplane, :skills, :access, :stop],
    [:backplane, :skills, :access, :exception],
    [:backplane, :host_agent, :connect],
    [:backplane, :host_agent, :disconnect]
  ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns runtime sink health."
  @spec health() :: map()
  def health do
    GenServer.call(__MODULE__, :health)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:event, event_name, measurements, metadata, DateTime.utc_now()})
    end

    :ok
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:backplane_telemetry, __MODULE__, [])
    merged = Backplane.Observability.RuntimeConfig.runtime_sink_opts(config)

    state = %{
      log_to_logger: Keyword.get(opts, :log_to_logger, Keyword.fetch!(merged, :log_to_logger)),
      log_to_console: Keyword.get(opts, :log_to_console, Keyword.fetch!(merged, :log_to_console)),
      log_to_file: Keyword.get(opts, :log_to_file, Keyword.fetch!(merged, :log_to_file)),
      accepted: 0,
      dropped: 0,
      failures: 0,
      last_flush_at: DateTime.utc_now()
    }

    attach()
    {:ok, state}
  end

  @impl true
  def handle_cast({:event, event_name, measurements, metadata, occurred_at}, state) do
    event = build_event(event_name, measurements, metadata, occurred_at)

    state =
      state
      |> Map.update!(:accepted, &(&1 + 1))
      |> write_event(event)

    {:noreply, %{state | last_flush_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: :ok,
       accepted: state.accepted,
       dropped: state.dropped,
       failures: state.failures,
       last_flush_at: state.last_flush_at,
       log_to_logger: state.log_to_logger,
       log_to_console: state.log_to_console,
       log_to_file: state.log_to_file
     }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    detach()
    :ok
  end

  defp write_event(state, event) do
    if state.log_to_logger, do: SinkLogger.log(event)

    state =
      if state.log_to_console do
        case Jason.encode(event) do
          {:ok, json} ->
            IO.puts(json)
            state

          {:error, _} ->
            Map.update!(state, :failures, &(&1 + 1))
        end
      else
        state
      end

    if state.log_to_file do
      case JSONL.write(event, path: state.log_to_file) do
        :ok -> state
        {:error, _} -> Map.update!(state, :failures, &(&1 + 1))
      end
    else
      state
    end
  rescue
    _ ->
      Map.update!(state, :failures, &(&1 + 1))
  end

  defp build_event(event_name, measurements, metadata, occurred_at) do
    {domain, operation, phase} = classify_event(event_name)

    %{
      schema_version: 1,
      event_id: Backplane.Observability.Id.event_id(),
      occurred_at: occurred_at,
      domain: domain,
      operation: operation,
      phase: phase,
      severity: if(phase == :exception, do: :error, else: :info),
      context: Map.take(metadata, [:request_id, :trace_id, :span_id, :client_id]),
      measurements: measurements,
      attributes: Backplane.Observability.Redaction.sanitize_attributes(metadata),
      error: metadata[:error],
      payload_ref: nil
    }
  end

  defp classify_event([:backplane, :llm, :request]), do: {:llm_proxy, "request", :stop}
  defp classify_event([:backplane, :mcp_request, :start]), do: {:mcp_proxy, "request", :start}
  defp classify_event([:backplane, :tool_call, phase]), do: {:mcp_proxy, "tool_call", phase}
  defp classify_event([:backplane, :memory, :access, phase]), do: {:memory, "access", phase}
  defp classify_event([:backplane, :memory, :event, outcome]), do: {:memory, "event", outcome}
  defp classify_event([:backplane, :host_agent, :memory, :call, phase]), do: {:host_agent, "memory_call", phase}
  defp classify_event([:backplane, :skills, :access, phase]), do: {:skills, "access", phase}
  defp classify_event([:backplane, :host_agent, :connect]), do: {:host_agent, "connect", :event}
  defp classify_event([:backplane, :host_agent, :disconnect]), do: {:host_agent, "disconnect", :event}

  defp classify_event([:backplane, domain | rest]) do
    case rest do
      [operation, phase] when is_atom(phase) ->
        {domain, Atom.to_string(operation), phase}

      [operation] ->
        {domain, Atom.to_string(operation), :event}

      _ ->
        {:system, Enum.join(Enum.map(rest, &Atom.to_string/1), "."), :event}
    end
  end

  defp classify_event(name) do
    {:system, Enum.join(Enum.map(name, &Atom.to_string/1), "."), :event}
  end

  defp attach do
    detach()
    :telemetry.attach_many(@handler_id, @legacy_events, &__MODULE__.handle_event/4, nil)
  end

  defp detach do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
