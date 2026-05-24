defmodule Backplane.HostAgent.Telemetry do
  @moduledoc """
  Telemetry helpers for host-agent runtime actions.
  """

  @memory_call_prefix [:backplane, :host_agent, :memory, :call]

  @doc "Wrap a memory call with telemetry instrumentation."
  @spec span_memory_call(String.t(), String.t(), map(), (-> term())) :: term()
  def span_memory_call(method, agent_id, args, fun)
      when is_binary(method) and is_map(args) and is_function(fun, 0) do
    metadata = %{
      agent_id: agent_id,
      argument_keys: argument_keys(args),
      method: method
    }

    :telemetry.span(@memory_call_prefix, metadata, fn ->
      result = fun.()
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  defp argument_keys(args) do
    args
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp result_metadata({:ok, _result}), do: %{result: :ok}
  defp result_metadata({:error, reason}), do: %{result: :error, error: inspect(reason)}
  defp result_metadata(_result), do: %{result: :ok}
end
