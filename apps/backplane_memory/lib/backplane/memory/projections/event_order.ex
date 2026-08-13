defmodule Backplane.Memory.Projections.EventOrder do
  @moduledoc false

  def sort(events) when is_list(events) do
    Enum.sort_by(events, &{&1.source_sequence, &1.event_type, &1.id})
  end
end
