defmodule Backplane.McpProtocol.Server.Registry.LocalTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Server.Registry.Local

  test "session names use the registry without creating atoms from session IDs" do
    registry_name = :"local_registry_#{System.unique_integer([:positive])}"
    session_id = "untrusted-#{System.unique_integer([:positive])}"
    unsafe_atom_name = "#{registry_name}.session.#{session_id}"

    start_supervised!({Local, name: registry_name})
    assert_missing_atom(unsafe_atom_name)

    session_name = Local.session_name(registry_name, session_id)
    assert {:via, Local, {^registry_name, ^session_id}} = session_name

    {:ok, pid} = Agent.start_link(fn -> :session end, name: session_name)
    assert {:ok, ^pid} = Local.lookup_session(registry_name, session_id)
    assert_missing_atom(unsafe_atom_name)

    Agent.stop(pid)

    assert eventually(fn ->
             Local.lookup_session(registry_name, session_id) == {:error, :not_found}
           end)
  end

  defp assert_missing_atom(name) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  defp eventually(fun) do
    Enum.reduce_while(1..10, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
