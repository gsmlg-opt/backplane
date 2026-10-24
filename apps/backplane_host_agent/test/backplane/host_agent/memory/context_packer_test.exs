defmodule Backplane.HostAgent.Memory.ContextPackerTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.ContextPacker

  test "final rendered budget includes labels, references, revisions and UTF-8, skipping whole oversized entries" do
    huge = %{
      "id" => "large",
      "content" => String.duplicate("界", 200),
      "trust" => "established_fact",
      "revision" => 8
    }

    small = %{
      "id" => "small",
      "content" => "Elixir",
      "trust" => "candidate_inference",
      "revision" => 3,
      "provisional" => true
    }

    complete = ContextPacker.pack([small], 1000)
    cost = byte_size(complete.rendered_context)

    assert %{results: [], rendered_context: "", used_tokens: 0} =
             ContextPacker.pack([small], cost - 1)

    result = ContextPacker.pack([huge, small], cost)
    assert result.results == [small]
    assert result.used_tokens == cost

    assert result.rendered_context =~
             "candidate inference; pending local memory; small; revision 3"

    assert String.ends_with?(result.rendered_context, "Elixir")
  end

  test "identity and revision deduplicate exact repeats while retaining independent equal content" do
    a = %{"id" => "a", "revision" => 1, "content" => "same", "trust" => "raw_evidence"}
    b = %{a | "id" => "b"}
    c = %{a | "revision" => 2}
    result = ContextPacker.pack([a, a, b, c], 1000)
    assert result.results == [a, b, c]
    assert result.used_tokens == byte_size(result.rendered_context)
    assert result.rendered_context =~ "raw evidence"
    refute result.rendered_context =~ "established fact"
  end
end
