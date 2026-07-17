defmodule Backplane.McpProtocol.Server.Registry do
  @moduledoc """
  Behaviour for pluggable session registries and deterministic naming utilities.

  The registry is responsible for mapping session IDs to PIDs. Different transports
  have different needs:

  - STDIO: single session, no registry needed (`Registry.None`)
  - HTTP: multiple sessions, need lookup by session ID (`Registry.Local`)

  ## Naming Utilities

  The module also provides deterministic atom naming for internal processes.
  These are safe because server modules are compile-time bounded.
  """

  @type session_id :: String.t()

  @callback child_spec(keyword()) :: Supervisor.child_spec() | :ignore
  @callback register_session(name :: term(), session_id(), pid()) :: :ok | {:error, term()}
  @callback lookup_session(name :: term(), session_id()) :: {:ok, pid()} | {:error, :not_found}
  @callback unregister_session(name :: term(), session_id()) :: :ok

  @doc """
  Returns the GenServer name for a session. Override this to return a `:via` tuple
  (e.g. `{:via, Horde.Registry, {name, session_id}}`) when using a distributed registry
  that auto-registers processes on `start_link`. The default returns a plain atom.

  When a `:via` tuple is returned, `register_session/3` should be a no-op since
  registration happens automatically on process start.
  """
  @callback session_name(registry_name :: term(), session_id()) :: GenServer.name()

  @optional_callbacks session_name: 2

  @doc """
  Resolves the session GenServer name via the registry adapter.

  Falls back to a non-atom global name if the adapter does not implement
  the optional `session_name/2` callback.
  """
  @spec resolve_session_name(module(), term(), session_id()) :: GenServer.name()
  def resolve_session_name(registry_mod, registry_name, session_id) do
    if function_exported?(registry_mod, :session_name, 2) do
      registry_mod.session_name(registry_name, session_id)
    else
      {:global, {__MODULE__, registry_name, session_id}}
    end
  end

  # Deterministic atom naming for internal processes

  @spec transport_name(module(), atom()) :: atom()
  def transport_name(server, type), do: :"Backplane.McpProtocol.#{server}.transport.#{type}"

  @spec task_supervisor_name(module()) :: atom()
  def task_supervisor_name(server), do: :"Backplane.McpProtocol.#{server}.task_supervisor"

  @doc """
  Default atom name for a server's `Backplane.McpProtocol.Server.TaskStore` process. Adapters
  may override via the optional `resolve_name/2` callback to return a `:via`
  tuple for distributed deployments.
  """
  @spec task_store_name(module()) :: atom()
  def task_store_name(server), do: :"Backplane.McpProtocol.#{server}.task_store"

  @spec session_supervisor_name(module()) :: atom()
  def session_supervisor_name(server), do: :"Backplane.McpProtocol.#{server}.session_supervisor"

  @spec supervisor_name(module()) :: atom()
  def supervisor_name(server), do: :"Backplane.McpProtocol.#{server}.supervisor"

  @spec session_name(module(), String.t()) :: atom()
  def session_name(server, session_id),
    do: :"Backplane.McpProtocol.#{server}.session.#{session_id}"

  @spec stdio_session_name(module()) :: atom()
  def stdio_session_name(server), do: :"Backplane.McpProtocol.#{server}.session.stdio"

  @spec registry_name(module()) :: atom()
  def registry_name(server), do: :"Backplane.McpProtocol.#{server}.registry"
end
