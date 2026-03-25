defmodule Backplane.Utils do
  @moduledoc """
  Shared utility functions used across Backplane modules.
  """

  @doc """
  Conditionally adds a key-value pair to a keyword list.
  Returns the list unchanged if the value is nil.
  """
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Format a tool origin for display."
  def format_origin(:native), do: "native"
  def format_origin({:upstream, prefix}), do: "upstream:#{prefix}"
end
