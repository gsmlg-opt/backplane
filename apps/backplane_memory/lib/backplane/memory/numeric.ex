defmodule Backplane.Memory.Numeric do
  @moduledoc false

  @spec unit_interval?(term()) :: boolean()
  def unit_interval?(value), do: is_number(value) and value >= 0 and value <= 1

  @spec nonnegative_score?(term()) :: boolean()
  def nonnegative_score?(value) when is_integer(value), do: value >= 0

  def nonnegative_score?(value) when is_float(value),
    do: value >= 0.0 and value <= 1.0e308

  def nonnegative_score?(_value), do: false

  @spec to_float(term()) :: {:ok, float()} | :error
  def to_float(value) when is_integer(value), do: {:ok, value / 1}
  def to_float(value) when is_float(value), do: {:ok, value}
  def to_float(_value), do: :error
end
