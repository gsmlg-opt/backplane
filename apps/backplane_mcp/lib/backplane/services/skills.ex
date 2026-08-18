defmodule Backplane.Services.Skills do
  @moduledoc "Managed MCP service for archive-backed Skills tools."

  @behaviour Backplane.Services.ManagedService

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Settings
  alias Backplane.Tools.Skill

  @setting_key "services.skill.enabled"

  @impl true
  def prefix, do: "skill"

  @impl true
  def enabled?, do: Settings.get(@setting_key) == true

  @impl true
  def tools do
    Enum.map(Skill.tools(), fn %{handler: handler} = tool ->
      tool |> Map.delete(:module) |> Map.put(:handler, fn args -> dispatch(handler, args) end)
    end)
  end

  @spec set_enabled(boolean()) :: :ok | {:error, term()}
  def set_enabled(enabled) when is_boolean(enabled) do
    with :ok <- Settings.set(@setting_key, enabled), do: sync_registry(enabled)
  end

  @spec sync_registry(boolean()) :: :ok
  def sync_registry(true) do
    ToolRegistry.deregister_managed(prefix())
    ToolRegistry.register_managed(prefix(), tools())
  end

  def sync_registry(false), do: ToolRegistry.deregister_managed(prefix())

  defp dispatch(handler, args) when is_atom(handler) and is_map(args) do
    if enabled?() do
      Skill.call(Map.put(args, "_handler", Atom.to_string(handler)))
    else
      {:error, %{code: "service_disabled", message: "Skills service is disabled"}}
    end
  end
end
