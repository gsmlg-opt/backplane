defmodule Backplane.HostAgent.Trace do
  @moduledoc """
  Trace context helpers for host-agent request and telemetry propagation.

  The current context is stored in the process dictionary because telemetry
  handlers run in the caller process that emits the event. This keeps trace
  enrichment local to the request without changing every telemetry call site.
  """

  @type ctx :: %{
          trace_id: String.t(),
          span_id: String.t(),
          parent_id: String.t() | nil
        }

  @context_key {__MODULE__, :ctx}
  @traceparent_regex ~r/^00-([0-9a-f]{32})-([0-9a-f]{16})-01$/

  @doc "Creates a new root trace context."
  @spec new_ctx() :: ctx()
  def new_ctx do
    %{
      trace_id: random_hex(16),
      span_id: random_hex(8),
      parent_id: nil
    }
  end

  @doc "Creates a child context from an existing context."
  @spec child_ctx(ctx() | nil) :: ctx() | nil
  def child_ctx(%{trace_id: trace_id, span_id: span_id}) do
    %{
      trace_id: trace_id,
      span_id: random_hex(8),
      parent_id: span_id
    }
  end

  def child_ctx(nil), do: nil

  @doc """
  Parses a W3C `traceparent` header.

  The incoming span id becomes the parent id for the local context.
  """
  @spec parse_traceparent(String.t() | nil) :: {:ok, ctx()} | :error
  def parse_traceparent(value) when is_binary(value) do
    case Regex.run(@traceparent_regex, value) do
      [_, trace_id, parent_id] ->
        {:ok, %{trace_id: trace_id, span_id: random_hex(8), parent_id: parent_id}}

      _ ->
        :error
    end
  end

  def parse_traceparent(_value), do: :error

  @doc "Formats a trace context as a W3C `traceparent` header."
  @spec to_traceparent(ctx()) :: String.t()
  def to_traceparent(%{trace_id: trace_id, span_id: span_id}) do
    "00-#{trace_id}-#{span_id}-01"
  end

  @doc "Runs `fun` with the current process trace context set to `ctx`."
  @spec with_ctx(ctx(), (-> result)) :: result when result: term()
  def with_ctx(ctx, fun) when is_function(fun, 0) do
    previous = Process.get(@context_key, :unset)
    Process.put(@context_key, ctx)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc "Returns the current process trace context, if one is active."
  @spec current() :: ctx() | nil
  def current, do: Process.get(@context_key)

  defp restore(:unset), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
