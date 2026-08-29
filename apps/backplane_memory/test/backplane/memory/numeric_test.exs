defmodule Backplane.Memory.NumericTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Numeric

  test "unit_interval?/1 accepts inclusive numeric bounds" do
    assert Numeric.unit_interval?(0)
    assert Numeric.unit_interval?(0.5)
    assert Numeric.unit_interval?(1)
  end

  test "unit_interval?/1 rejects values outside the unit interval and nonnumbers" do
    refute Numeric.unit_interval?(-0.1)
    refute Numeric.unit_interval?(1.1)
    refute Numeric.unit_interval?("0.5")
  end

  test "nonnegative_score?/1 preserves its integer and bounded float domains" do
    assert Numeric.nonnegative_score?(Integer.pow(10, 400))
    assert Numeric.nonnegative_score?(1.0e308)
    refute Numeric.nonnegative_score?(-1)
    refute Numeric.nonnegative_score?(1.1e308)
    refute Numeric.nonnegative_score?(:score)
  end

  test "to_float/1 converts integers, preserves floats, and rejects other values" do
    assert {:ok, 1.0} = Numeric.to_float(1)
    assert {:ok, 0.5} = Numeric.to_float(0.5)
    assert :error = Numeric.to_float("1")
  end
end
