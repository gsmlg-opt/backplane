defmodule Backplane.Cache.KeyBuilder do
  @moduledoc """
  Deterministic cache key construction for upstream tool results.
  """

  @doc "Build a cache key for an upstream tool call result."
  @spec upstream(String.t(), String.t(), map()) :: tuple()
  def upstream(prefix, tool_name, arguments) do
    {:upstream, prefix, tool_name, hash_params(arguments)}
  end

  defp hash_params(nil), do: nil
  defp hash_params(params) when params == %{}, do: nil

  defp hash_params(params) when is_map(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_params(params) when is_list(params) do
    params
    |> Enum.sort()
    |> inspect()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_params(params) do
    params
    |> inspect()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
