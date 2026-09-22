defmodule Backplane.Memory.Slots.Reflect do
  @moduledoc """
  Legacy stop-hook slot reflection. Server-side reflection requires a device-local
  partition, so this entry point does not read observations or write slots.
  """

  @doc "Return why server-side slot reflection did not run."
  def run(_session_id) do
    if Backplane.Settings.get("memory.reflect_enabled") == "true" do
      {:skip, :device_local_only}
    else
      {:skip, :disabled}
    end
  end
end
