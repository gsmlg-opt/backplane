defmodule Backplane.McpProtocol.Server.RegistryTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Server.Registry

  defmodule RegistryWithoutSessionName do
    @behaviour Registry

    @impl Registry
    def child_spec(_opts), do: :ignore

    @impl Registry
    def register_session(_name, _session_id, _pid), do: :ok

    @impl Registry
    def lookup_session(_name, _session_id), do: {:error, :not_found}

    @impl Registry
    def unregister_session(_name, _session_id), do: :ok
  end

  test "fallback session names do not create atoms from session IDs" do
    registry_name = :"registry_without_session_name_#{System.unique_integer([:positive])}"
    session_id = "untrusted-#{System.unique_integer([:positive])}"
    unsafe_atom_name = "#{registry_name}.session.#{session_id}"

    assert_missing_atom(unsafe_atom_name)

    assert {:global, {Registry, ^registry_name, ^session_id}} =
             Registry.resolve_session_name(
               RegistryWithoutSessionName,
               registry_name,
               session_id
             )

    assert_missing_atom(unsafe_atom_name)
  end

  defp assert_missing_atom(name) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
