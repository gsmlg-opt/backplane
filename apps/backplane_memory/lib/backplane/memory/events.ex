defmodule Backplane.Memory.Events do
  alias Backplane.Memory.Events.{Query, Store}

  def append(attrs), do: Store.append(attrs)
  def append_batch(attrs), do: Store.append_batch(attrs)

  def range(stream_id, range), do: Query.range(stream_id, range)
  def timeline(filters), do: Query.timeline(filters)
  def close_stream(stream_id), do: Store.close_stream(stream_id)
end
