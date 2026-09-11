defmodule Backplane.AgentRuntime.Execution do
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store

  @moduledoc """
  Coordination helpers for deterministic transitions and asynchronous effects.

  No external effect is dispatched before a committed store acknowledgement.
  Late or stale results are fenced by run, invocation, attempt, and incarnation.
  """

  @spec run(Store, term(), map(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def run(store, context, record, meta, opts \\ [])
      when is_atom(store) and is_map(record) and is_map(meta) and is_list(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    with {:ok, committed} <- Store.store(store, context, record, meta) do
      case adapter_for(meta.command) do
        :provider -> run_provider(adapter, committed)
        :tool -> run_tool(adapter, committed)
        :none -> {:ok, committed, %{effects: [], fenced: []}}
      end
    end
  end

  defp run_provider(adapter, committed) do
    case adapter.start(%{committed: committed}) do
      {:ok, response} -> {:ok, committed, %{effects: [response], fenced: []}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp run_tool(adapter, committed) do
    case adapter.execute(%{committed: committed}) do
      {:ok, result} -> {:ok, committed, %{effects: [result], fenced: []}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp adapter_for({:provider_started, _, _}), do: :provider
  defp adapter_for({:tool_invoked, _, _}), do: :tool
  defp adapter_for(_), do: :none
end
