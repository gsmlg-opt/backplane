defmodule Backplane.AgentRuntime.Usage do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Attempt-attributed usage accounting without double counting.

  The same report identity is idempotent. Missing values remain `:unknown`
  instead of being treated as zero. Context occupancy is tracked separately
  from lifetime totals.
  """

  @type t :: map()

  @spec new() :: {:ok, t()}
  def new, do: {:ok, %{reports: %{}, totals: empty(), occupancy: %{}}}

  @spec report(t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def report(usage, input) when is_map(usage) and is_map(input) do
    with {:ok, identity} <- require_binary(input, :identity, "identity"),
         {:ok, delta} <- validate_report(input) do
      case Map.get(usage.reports, identity) do
        %{digest: digest} ->
          if digest == report_digest(delta) do
            {:ok, usage, %{status: :duplicate, identity: identity}}
          else
            {:error,
             Backplane.AgentRuntime.Error.new(:resource_conflict, "usage report conflict")}
          end

          {:ok, usage, %{status: :duplicate, identity: identity}}

        nil ->
          totals = add_reports(usage.totals, delta)

          updated = %{
            usage
            | reports: Map.put(usage.reports, identity, %{digest: report_digest(delta)}),
              totals: totals,
              occupancy:
                Map.update(
                  usage.occupancy,
                  Map.get(input, :context_id, "default"),
                  Map.get(delta, :occupancy_tokens, :unknown),
                  fn _existing -> Map.get(delta, :occupancy_tokens, :unknown) end
                )
          }

          updated =
            Map.put(updated, :reported, Map.get(updated, :reports))

          {:ok, updated, %{status: :recorded, identity: identity}}
      end
    end
  end

  @spec totals(t()) :: map()
  def totals(%{totals: totals}), do: totals

  defp validate_report(input) do
    delta = %{
      input_tokens: metric(Map.get(input, :input_tokens)),
      output_tokens: metric(Map.get(input, :output_tokens)),
      cached_tokens: metric(Map.get(input, :cached_tokens)),
      reasoning_tokens: metric(Map.get(input, :reasoning_tokens)),
      occupancy_tokens: metric(Map.get(input, :occupancy_tokens))
    }

    if Map.values(delta) |> Enum.all?(&((is_integer(&1) and &1 >= 0) or &1 == :unknown)) do
      {:ok, delta}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "usage values must be non-negative")}
    end
  end

  defp metric(nil), do: :unknown
  defp metric(value) when is_integer(value) and value >= 0, do: value
  defp metric(:unknown), do: :unknown

  defp add_reports(left, right) do
    %{
      input_tokens: add(left.input_tokens, right.input_tokens),
      output_tokens: add(left.output_tokens, right.output_tokens),
      cached_tokens: add(left.cached_tokens, right.cached_tokens),
      reasoning_tokens: add(left.reasoning_tokens, right.reasoning_tokens)
    }
  end

  defp add(:unknown, value), do: value
  defp add(value, :unknown), do: value
  defp add(left, right) when is_integer(left) and is_integer(right), do: left + right

  defp report_digest(delta) do
    :crypto.hash(:sha256, :erlang.term_to_binary(delta)) |> Base.encode16()
  end

  defp empty do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0
    }
  end

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "#{label} is required")}
    end
  end
end
