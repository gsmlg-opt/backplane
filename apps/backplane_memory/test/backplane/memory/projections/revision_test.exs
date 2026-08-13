defmodule Backplane.Memory.Projections.RevisionTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.Revision

  test "output revision recursively canonicalizes JSON object ordering" do
    left = %{"z" => [%{"b" => 2, "a" => 1}], "a" => %{"two" => 2, "one" => 1}}
    right = %{"a" => %{"one" => 1, "two" => 2}, "z" => [%{"a" => 1, "b" => 2}]}

    assert {:ok, left_revision} = Revision.output_revision(left)
    assert {:ok, right_revision} = Revision.output_revision(right)
    assert left_revision == right_revision
    assert left_revision =~ ~r/^[0-9a-f]{64}$/

    assert {:ok, ~s({"a":{"one":1,"two":2},"z":[{"a":1,"b":2}]})} =
             Revision.encode_json(right)
  end

  test "output revision rejects non-JSON-safe values at any depth" do
    for value <- [
          %{atom_key: "value"},
          %{"atom" => :value},
          %{"tuple" => {:not, :json}},
          %{"pid" => self()},
          %{"improper" => [1 | 2]},
          %{"datetime" => ~U[2026-08-04 01:00:00Z]}
        ] do
      assert {:error, :not_json_safe} = Revision.output_revision(value)
    end
  end

  test "input revision uses only canonical ordered event tuples" do
    one = %Event{
      id: "b",
      payload_hash: "hash-b",
      source_sequence: 1,
      event_type: "same",
      payload: %{"ignored" => 1}
    }

    two = %Event{
      id: "a",
      payload_hash: "hash-a",
      source_sequence: 1,
      event_type: "same",
      payload: %{"ignored" => 2}
    }

    assert Revision.input_revision([one, two]) == Revision.input_revision([two, one])
    assert Revision.input_revision([one, two]) =~ ~r/^[0-9a-f]{64}$/

    refute Revision.input_revision([one, two]) ==
             Revision.input_revision([%{two | payload_hash: "changed"}, one])
  end
end
