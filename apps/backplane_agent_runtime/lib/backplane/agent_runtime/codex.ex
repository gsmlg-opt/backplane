defmodule Backplane.AgentRuntime.Codex do
  @moduledoc """
  Public entry point for explicit, host-configured Codex tool profiles.

  `definitions/0` retains the executable local definitions for compatibility.
  `profile/4` is the model-callable boundary for local, control, collaboration,
  extension, dynamic, Code Mode, service, and composed profiles.
  """

  alias Backplane.AgentRuntime.Codex.Services
  alias Backplane.AgentRuntime.Codex.{Profile, Tools}

  def definitions, do: Tools.definitions()

  def profile(profile, context, authority, opts \\ []),
    do: Profile.build(profile, context, authority, opts)

  def call(context, name, arguments), do: Tools.call(context, name, arguments)
  def service_definitions, do: Services.definitions()
  def service_call(context, name, arguments), do: Services.call(context, name, arguments)
end
