defmodule Backplane.Memory.QueryLogFilter do
  @moduledoc false

  @filter_id :backplane_memory_query_log_filter
  @memory_table_markers ["bpm_", "memory_"]

  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  def uninstall do
    case :logger.remove_primary_filter(@filter_id) do
      :ok -> :ok
      {:error, {:not_found, @filter_id}} -> :ok
    end
  end

  def filter(%{msg: {:string, message}} = event, _state) when is_list(message) do
    if memory_query?(message) do
      %{event | msg: {:string, "MEMORY QUERY [parameters redacted]"}}
    else
      event
    end
  end

  def filter(event, _state), do: event

  defp memory_query?(["QUERY" | rest]) do
    with {_header, [10, query | _params]} <- Enum.split_while(rest, &(&1 != 10)),
         true <- is_binary(query) do
      Enum.any?(@memory_table_markers, &String.contains?(query, &1))
    else
      _other -> false
    end
  end

  defp memory_query?(_message), do: false
end
