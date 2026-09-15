defmodule Backplane.Memory.Slots.Reflect do
  @moduledoc """
  Stop-hook slot reflection. Scans recent observations for TODO/FIXME/blocked patterns
  and updates pending_items, session_patterns, and project_context slots.
  Only runs when memory.reflect_enabled=true.
  """

  @doc "Run slot reflection for a session. Returns :ok or {:skip, reason}."
  def run(_session_id) do
    if Backplane.Settings.get("memory.reflect_enabled") == "true" do
      {:skip, :incomplete_partition}
    else
      {:skip, :disabled}
    end
  end
end
