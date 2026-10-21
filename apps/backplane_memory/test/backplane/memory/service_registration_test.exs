defmodule Backplane.Memory.ServiceRegistrationTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Service, ServiceRegistration}
  alias Backplane.Registry.{PromptRegistry, ToolRegistry}
  alias Backplane.Settings

  @key "services.memory.enabled"

  defmodule UnavailableSettings do
    def subscribe, do: Backplane.Settings.subscribe()
    def fetch_many(_keys), do: {:error, :load_failed}
  end

  setup_all do
    if supervisor = Process.whereis(Backplane.Memory.Supervisor) do
      {ServiceRegistration, pid, :worker, [ServiceRegistration]} =
        List.keyfind(Supervisor.which_children(supervisor), ServiceRegistration, 0)

      assert is_pid(pid)
      assert Process.whereis(ServiceRegistration) == pid
      cached = :ets.lookup(:backplane_settings, @key)
      assert :ok = Supervisor.terminate_child(supervisor, ServiceRegistration)

      on_exit(fn ->
        assert :ets.lookup(:backplane_settings, @key) == cached
        assert {:ok, restored} = Supervisor.restart_child(supervisor, ServiceRegistration)
        assert Process.whereis(ServiceRegistration) == restored
      end)
    end

    :ok
  end

  setup do
    assert {:ok, _} = Settings.fetch_many([@key])
    settings_state = :sys.get_state(Settings)
    cached = :ets.lookup(:backplane_settings, @key)
    tools = Enum.filter(ToolRegistry.list_all(), &(&1.origin == {:managed, "memory"}))
    prompts = Enum.filter(PromptRegistry.list(), &(&1.prefix == "memory"))
    clear_registration()

    on_exit(fn ->
      :sys.replace_state(Settings, fn _ -> settings_state end)
      :ets.delete(:backplane_settings, @key)
      if cached != [], do: :ets.insert(:backplane_settings, cached)
      clear_registration()
      if tools != [], do: ToolRegistry.register_managed("memory", tools)

      if prompts != [],
        do: PromptRegistry.register_managed("memory", Enum.map(prompts, & &1.descriptor), Service)
    end)

    :ok
  end

  test "application shutdown removes both memory tools and prompts" do
    register_stale_entries()
    assert :ok = Backplane.Memory.Application.stop(nil)
    assert hidden?()
  end

  test "a persisted enabled service registers both catalogs" do
    assert :ok = Settings.set(@key, true)
    start_registration()
    assert eventually(&visible?/0)
  end

  test "a persisted disabled service removes stale entries from both catalogs" do
    register_stale_entries()
    assert :ok = Settings.set(@key, false)
    start_registration()
    assert eventually(&hidden?/0)
  end

  test "an unready Settings cache is never treated as canonical and retries after readiness" do
    assert :ok = Settings.set(@key, true)
    :sys.replace_state(Settings, &Map.put(&1, :load_status, :loading))
    pid = start_registration()
    :sys.get_state(pid)
    assert hidden?()

    :sys.replace_state(Settings, &Map.put(&1, :load_status, :ok))
    assert eventually(&visible?/0)
  end

  test "an authoritative Settings load failure hides stale registered entries" do
    assert :ok = Settings.set(@key, true)
    register_stale_entries()
    pid = start_registration(settings_module: UnavailableSettings)
    :sys.get_state(pid)
    assert hidden?()
    send(pid, {:setting_changed, @key, true})
    :sys.get_state(pid)
    assert hidden?()
  end

  test "persisted runtime toggles update tools and prompts and stale events cannot enable them" do
    assert :ok = Settings.set(@key, false)
    pid = start_registration()
    assert eventually(&hidden?/0)

    assert :ok = Settings.set(@key, true)
    assert eventually(&visible?/0)
    assert :ok = Settings.set(@key, false)
    assert eventually(&hidden?/0)

    send(pid, {:setting_changed, @key, true})
    :sys.get_state(pid)
    assert hidden?()
    assert :ok = Settings.set(@key, true)
    assert eventually(&visible?/0)
  end

  test "stopping the registration worker removes both catalogs" do
    assert :ok = Settings.set(@key, true)
    start_registration()
    assert eventually(&visible?/0)
    assert :ok = stop_supervised(ServiceRegistration)
    assert hidden?()
  end

  defp start_registration(opts \\ []) do
    start_supervised!({ServiceRegistration, Keyword.put(opts, :retry_interval_ms, 10)})
  end

  defp register_stale_entries do
    :ok = ToolRegistry.register_managed("memory", Service.tools())
    :ok = PromptRegistry.register_managed("memory", Service.prompts(), Service)
    assert visible?()
  end

  defp clear_registration do
    :ok = ToolRegistry.deregister_managed("memory")
    :ok = PromptRegistry.deregister_managed("memory")
  end

  defp visible? do
    not is_nil(ToolRegistry.lookup("memory::remember")) and
      Enum.any?(PromptRegistry.list(), &(&1.prefix == "memory"))
  end

  defp hidden? do
    Enum.all?(ToolRegistry.list_all(), &(&1.origin != {:managed, "memory"})) and
      Enum.all?(PromptRegistry.list(), &(&1.prefix != "memory"))
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
