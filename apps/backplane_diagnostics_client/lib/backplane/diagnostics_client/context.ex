defmodule Backplane.DiagnosticsClient.Context do
  @moduledoc "Explicit process-local propagation for diagnostics subjects and execution links."

  @fields ~w(subject correlation)

  def current, do: Process.get(__MODULE__, %{})

  def with_context(context, run) when is_map(context) and is_function(run, 0) do
    previous = Process.get(__MODULE__)
    Process.put(__MODULE__, Map.take(context, @fields))

    try do
      run.()
    after
      if is_nil(previous), do: Process.delete(__MODULE__), else: Process.put(__MODULE__, previous)
    end
  end

  def attach(event) when is_map(event) do
    Enum.reduce(current(), event, fn {key, context}, acc ->
      Map.update(acc, key, context, fn
        explicit when is_map(explicit) and is_map(context) -> Map.merge(context, explicit)
        explicit -> explicit
      end)
    end)
  end
end
