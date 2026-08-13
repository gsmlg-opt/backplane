defmodule Backplane.Registry.PromptRegistryTest do
  use ExUnit.Case, async: false

  alias Backplane.Registry.{PromptCatalog, PromptRegistry}

  defmodule MemoryPrompts do
    def get_prompt(name, args, auth), do: {:ok, %{name: name, args: args, auth: auth}}
  end

  defmodule OtherPrompts do
    def get_prompt(name, args, auth), do: {:ok, %{name: name, args: args, auth: auth}}
  end

  setup do
    PromptRegistry.clear()
    :ok
  end

  test "registers deterministic public descriptors and dispatch metadata" do
    prompts = [
      %{name: "session_handoff", description: "Handoff", arguments: []},
      %{name: "recall_context", description: "Recall", arguments: [%{name: "query"}]}
    ]

    assert :ok = PromptRegistry.register_managed("memory", prompts, MemoryPrompts)

    assert Enum.map(PromptRegistry.list(), & &1.name) == ["recall_context", "session_handoff"]

    assert %{
             name: "recall_context",
             prefix: "memory",
             permission: "memory.read",
             scope_target: "memory::recall_context",
             descriptor: %{description: "Recall"},
             service: MemoryPrompts
           } = PromptRegistry.lookup("recall_context")
  end

  test "managed names are reserved across prefixes and deregistration releases ownership" do
    descriptor = %{name: "recall_context", description: "Recall", arguments: []}

    assert :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)

    assert {:error, :name_reserved} =
             PromptRegistry.register_managed("other", [descriptor], MemoryPrompts)

    assert :ok = PromptRegistry.deregister_managed("memory")
    assert nil == PromptRegistry.lookup("recall_context")
    assert :ok = PromptRegistry.register_managed("other", [descriptor], MemoryPrompts)
  end

  test "registry rehydrates managed prompts after its ETS owner restarts" do
    descriptor = %{name: "recall_context", description: "Recall", arguments: []}
    :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)

    restart_cleanly(PromptRegistry)
    assert [%{name: "recall_context", prefix: "memory"}] = PromptRegistry.list()
  end

  test "deregistration remains effective after the registry restarts" do
    descriptor = %{name: "recall_context", description: "Recall", arguments: []}
    :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)
    :ok = PromptRegistry.deregister_managed("memory")

    restart_cleanly(PromptRegistry)
    assert PromptRegistry.lookup("recall_context") == nil
  end

  test "rehydrated names remain reserved across prefixes" do
    descriptor = %{name: "recall_context", description: "Recall", arguments: []}
    :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)

    restart_cleanly(PromptRegistry)

    assert {:error, :name_reserved} =
             PromptRegistry.register_managed("other", [descriptor], MemoryPrompts)

    assert %{prefix: "memory"} = PromptRegistry.lookup("recall_context")
  end

  test "catalog crash preserves desired registrations and later mutations" do
    recall = %{name: "recall_context", description: "Recall", arguments: []}
    handoff = %{name: "session_handoff", description: "Handoff", arguments: []}
    agenda = %{name: "daily_agenda", description: "Agenda", arguments: []}

    :ok = PromptRegistry.register_managed("memory", [recall], MemoryPrompts)
    :ok = PromptRegistry.register_managed("other", [agenda], OtherPrompts)

    kill_and_restart(PromptCatalog)

    assert PromptCatalog.entries() |> Enum.map(& &1.name) |> Enum.sort() ==
             ["daily_agenda", "recall_context"]

    :ok = PromptRegistry.deregister_managed("memory")
    assert Enum.map(PromptRegistry.list(), & &1.name) == ["daily_agenda"]

    :ok = PromptRegistry.register_managed("memory", [handoff], MemoryPrompts)

    assert Enum.map(PromptRegistry.list(), & &1.name) ==
             ["daily_agenda", "session_handoff"]

    :ok = PromptRegistry.clear()
    assert PromptRegistry.list() == []

    :ok = PromptRegistry.register_managed("memory", [recall], MemoryPrompts)
    :ok = PromptRegistry.register_managed("other", [agenda], OtherPrompts)

    kill_and_restart(PromptRegistry)

    assert Enum.map(PromptRegistry.list(), & &1.name) ==
             ["daily_agenda", "recall_context"]
  end

  test "clear and clean application stop remove crash-surviving desired entries" do
    descriptor = %{name: "recall_context", description: "Recall", arguments: []}
    :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)
    :ok = PromptRegistry.clear()

    restart_cleanly(PromptCatalog)
    assert PromptCatalog.entries() == []

    :ok = PromptRegistry.register_managed("memory", [descriptor], MemoryPrompts)
    assert :ok = BackplaneSystem.Application.stop(:ignored)

    restart_cleanly(PromptCatalog)
    assert PromptCatalog.entries() == []
  end

  defp kill_and_restart(module) do
    old_pid = Process.whereis(module)
    Process.exit(old_pid, :kill)
    assert is_pid(wait_for_restart(module, old_pid))
  end

  defp restart_cleanly(module) do
    supervisor = BackplaneSystem.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, module)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, module)
  end

  defp wait_for_restart(module, old_pid, attempts \\ 50)
  defp wait_for_restart(_module, _old_pid, 0), do: nil

  defp wait_for_restart(module, old_pid, attempts) do
    case Process.whereis(module) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_restart(module, old_pid, attempts - 1)
    end
  end
end
