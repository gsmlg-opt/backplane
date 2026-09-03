defmodule Backplane.Observability.IdTest do
  use ExUnit.Case, async: true

  alias Backplane.Observability.Id

  test "generates stable-length identifiers" do
    assert byte_size(Id.event_id()) == 32
    assert byte_size(Id.trace_id()) == 32
    assert byte_size(Id.span_id()) == 16
    assert byte_size(Id.request_id()) == 16
  end

  test "generates unique event ids" do
    ids = for _ <- 1..20, do: Id.event_id()
    assert length(Enum.uniq(ids)) == 20
  end
end
