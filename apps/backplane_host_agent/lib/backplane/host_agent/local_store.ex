defmodule Backplane.HostAgent.LocalStore do
  @moduledoc """
  Small local target lookup helpers for the host agent.
  """

  def enabled_targets(targets) do
    Enum.filter(targets, fn target -> field(target, :enabled, true) end)
  end

  def target_by_name(targets, name) do
    Enum.find(targets, fn target -> field(target, :name) == name end)
  end

  def field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
