defmodule Backplane.ApplicationTest do
  use ExUnit.Case, async: true

  test "prep_stop returns state and does not crash" do
    # prep_stop should be resilient — it rescues all errors
    state = %{some: :state}
    result = Backplane.Application.prep_stop(state)
    assert result == state
  end
end
