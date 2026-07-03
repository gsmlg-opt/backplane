defmodule Backplane.McpProtocol.Server.Registry.None do
  @moduledoc """
  No-op registry for STDIO transport.

  STDIO has exactly one session, looked up by atom name. No registry needed.
  """

  @behaviour Backplane.McpProtocol.Server.Registry

  @impl Backplane.McpProtocol.Server.Registry
  def child_spec(_opts), do: :ignore

  @impl Backplane.McpProtocol.Server.Registry
  def session_name(_registry_name, session_id), do: :"Backplane.McpProtocol.stdio.session.#{session_id}"

  @impl Backplane.McpProtocol.Server.Registry
  def register_session(_name, _session_id, _pid), do: :ok

  @impl Backplane.McpProtocol.Server.Registry
  def lookup_session(_name, _session_id), do: {:error, :not_found}

  @impl Backplane.McpProtocol.Server.Registry
  def unregister_session(_name, _session_id), do: :ok
end
