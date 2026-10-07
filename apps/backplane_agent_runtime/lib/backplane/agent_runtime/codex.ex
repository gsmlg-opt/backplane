defmodule Backplane.AgentRuntime.Codex do
  @moduledoc """
  Public entry point for explicit, host-configured Codex tool profiles.

  `definitions/0` retains the executable local definitions for compatibility.
  `profile/4` is the model-callable boundary for local, control, collaboration,
  extension, dynamic, Code Mode, service, and composed profiles.
  """

  alias Backplane.AgentRuntime.Codex.Services
  alias Backplane.AgentRuntime.Codex.{Profile, Tools}
  alias Backplane.AgentRuntime.Error

  def definitions, do: Tools.definitions()

  def profile(profile, context, authority, opts \\ [])

  def profile(profile, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    case Map.get(context, :session_binding) do
      nil ->
        Profile.build(profile, context, authority, opts)

      %{run_id: run, resource_registry: registry} = binding when run == authority.run_id ->
        context =
          context |> Map.put(:resource_registry, registry) |> Map.put(:session_registry, registry)

        with {:ok, bundle} <- Profile.build(profile, context, authority, opts) do
          tools =
            Map.new(bundle.registry.tools, fn {name, descriptor} ->
              backend = Map.put(descriptor.backend_context, :session_binding, binding)
              {name, Map.put(descriptor, :backend_context, backend)}
            end)

          {:ok,
           bundle
           |> Map.put(:registry, %{bundle.registry | tools: tools})
           |> Map.put(:session_binding, binding)}
        end

      _ ->
        {:error, Error.new(:forbidden, "profile session binding does not match run authority")}
    end
  end

  def profile(profile, context, authority, opts),
    do: Profile.build(profile, context, authority, opts)

  def call(context, name, arguments), do: Tools.call(context, name, arguments)
  def service_definitions, do: Services.definitions()
  def service_call(context, name, arguments), do: Services.call(context, name, arguments)
end
