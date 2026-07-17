defmodule Backplane.Memory.Operations.RolloutTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Operations
  alias Backplane.Settings

  @pipeline "memory.pipeline.enabled"
  @events "memory.events.enabled"
  @dual_write "memory.events.dual_write"
  @gate_keys [@pipeline, @events, @dual_write]

  defmodule FailingSettings do
    def get_many(keys), do: Backplane.Settings.get_many(keys)
    def subscribe, do: Backplane.Settings.subscribe()

    def set_if(_key, _value, _expectations),
      do: {:error, :forced_setting_failure}
  end

  setup do
    previous_adapter = Application.fetch_env(:backplane_memory, :settings_adapter)
    Application.delete_env(:backplane_memory, :settings_adapter)

    snapshot = Map.new(@gate_keys, &{&1, Settings.get(&1)})
    set_configured(false, false, false)

    on_exit(fn ->
      restore_application_env(:settings_adapter, previous_adapter)
      Enum.each(snapshot, fn {key, value} -> assert :ok = Settings.set(key, value) end)
    end)

    :ok
  end

  test "reports configured and effective state for the valid hierarchy" do
    expected_later = [
      {"memory.window_summaries.enabled", "Window Summaries"},
      {"memory.session_summary_v2.enabled", "Session Summary V2"},
      {"memory.fact_extraction_v2.enabled", "Fact Extraction V2"},
      {"memory.procedure_extraction_v2.enabled", "Procedure Extraction V2"},
      {"memory.recall_v2.enabled", "Recall V2"}
    ]

    for {configured, effective} <- [
          {{false, false, false}, {false, false, false}},
          {{true, false, false}, {true, false, false}},
          {{true, true, false}, {true, true, false}},
          {{true, true, true}, {true, true, true}}
        ] do
      set_configured(Tuple.to_list(configured))
      rollout = Operations.rollout_state()

      assert gate_values(rollout, :configured) == Tuple.to_list(configured)
      assert gate_values(rollout, :effective) == Tuple.to_list(effective)
      assert gate_values(rollout, :blocked) == [false, false, false]

      assert Enum.map(rollout.later, &{&1.key, &1.label}) == expected_later
      assert length(rollout.later) == 5
      assert Enum.all?(rollout.later, &(&1.available == false))
    end
  end

  test "reports configured children blocked by a disabled parent" do
    set_configured(false, true, true)

    rollout = Operations.rollout_state()

    assert gate_values(rollout, :configured) == [false, true, true]
    assert gate_values(rollout, :effective) == [false, false, false]
    assert gate_values(rollout, :blocked) == [false, true, true]
  end

  test "treats nonboolean configured values as disabled" do
    assert :ok = Settings.set(@pipeline, "true")
    assert :ok = Settings.set(@events, 1)
    assert :ok = Settings.set(@dual_write, %{"enabled" => true})

    rollout = Operations.rollout_state()

    assert gate_values(rollout, :configured) == [false, false, false]
    assert gate_values(rollout, :effective) == [false, false, false]
  end

  test "allows every hierarchy-preserving transition" do
    allowed = [
      {{false, false, false}, :pipeline, true, {true, false, false}},
      {{true, false, false}, :events, true, {true, true, false}},
      {{true, true, false}, :dual_write, true, {true, true, true}},
      {{true, true, true}, :dual_write, false, {true, true, false}},
      {{true, true, false}, :events, false, {true, false, false}},
      {{true, false, false}, :pipeline, false, {false, false, false}}
    ]

    for {initial, gate, value, expected} <- allowed do
      set_configured(Tuple.to_list(initial))

      assert :ok = Operations.set_gate(gate, value)
      assert gate_values(Operations.rollout_state(), :configured) == Tuple.to_list(expected)
    end
  end

  test "refuses every transition that would violate the hierarchy" do
    refused = [
      {{false, true, false}, :pipeline, true, {:blocked_descendant, :events}},
      {{false, false, true}, :pipeline, true, {:blocked_descendant, :dual_write}},
      {{false, false, false}, :events, true, {:dependency, :pipeline, true}},
      {{true, false, true}, :events, true, {:dependency, :dual_write, false}},
      {{false, true, false}, :dual_write, true, {:dependency, :events, true}},
      {{true, false, false}, :dual_write, true, {:dependency, :events, true}},
      {{true, true, true}, :events, false, {:dependency, :dual_write, false}},
      {{true, true, false}, :pipeline, false, {:blocked_descendant, :events}},
      {{true, false, true}, :pipeline, false, {:blocked_descendant, :dual_write}}
    ]

    for {initial, gate, value, error} <- refused do
      set_configured(Tuple.to_list(initial))

      assert {:error, ^error} = Operations.set_gate(gate, value)
      assert gate_values(Operations.rollout_state(), :configured) == Tuple.to_list(initial)
    end
  end

  test "rejects unknown gates and nonboolean values" do
    for gate <- [:unknown, "pipeline", "memory.pipeline.enabled"] do
      assert {:error, :invalid_gate} = Operations.set_gate(gate, true)
    end

    for value <- [nil, 0, 1, "true", %{}, []] do
      assert {:error, :invalid_boolean} = Operations.set_gate(:pipeline, value)
    end
  end

  test "recovers an inconsistent hierarchy from the deepest child upward" do
    set_configured(false, true, true)

    assert {:error, {:dependency, :dual_write, false}} =
             Operations.set_gate(:events, false)

    assert {:error, {:blocked_descendant, :events}} =
             Operations.set_gate(:pipeline, true)

    assert :ok = Operations.set_gate(:dual_write, false)
    assert gate_values(Operations.rollout_state(), :configured) == [false, true, false]

    assert :ok = Operations.set_gate(:events, false)
    assert gate_values(Operations.rollout_state(), :configured) == [false, false, false]
  end

  test "successful mutations broadcast the existing setting message" do
    assert :ok = Operations.subscribe_rollout()

    assert :ok = Operations.set_gate(:pipeline, true)
    assert_receive {:setting_changed, @pipeline, true}
  end

  test "adapter failures propagate without changing configured state" do
    Application.put_env(:backplane_memory, :settings_adapter, FailingSettings)

    assert {:error, :forced_setting_failure} =
             Operations.set_gate(:pipeline, true)

    assert Settings.get(@pipeline) == false
    assert Operations.rollout_state().pipeline.configured == false
  end

  test "concurrent valid transitions cannot commit an invalid hierarchy" do
    assert :ok = Settings.set(@pipeline, true)
    assert :ok = Settings.set(@events, true)
    assert :ok = Settings.set(@dual_write, false)

    settings_pid = Process.whereis(Settings)
    on_exit(fn -> :sys.resume(settings_pid) end)
    :ok = :sys.suspend(settings_pid)

    tasks =
      try do
        tasks = [
          Task.async(fn -> Operations.set_gate(:events, false) end),
          Task.async(fn -> Operations.set_gate(:dual_write, true) end)
        ]

        assert eventually(fn -> queued_set_if_calls(settings_pid) == 2 end)
        tasks
      after
        :sys.resume(settings_pid)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &(&1 == :ok)) == 1

    assert Enum.count(results, fn
             {:error, {:dependency, _, _}} -> true
             _other -> false
           end) == 1

    rollout = Operations.rollout_state()

    refute rollout.events.configured and not rollout.pipeline.configured
    refute rollout.dual_write.configured and not rollout.events.configured

    assert {rollout.events.configured, rollout.dual_write.configured} in [
             {false, false},
             {true, true}
           ]
  end

  defp queued_set_if_calls(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {:set_if, _key, _value, _expectations}} -> true
      _other -> false
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp gate_values(rollout, field) do
    for gate <- [:pipeline, :events, :dual_write] do
      rollout |> Map.fetch!(gate) |> Map.fetch!(field)
    end
  end

  defp set_configured([pipeline, events, dual_write]) do
    set_configured(pipeline, events, dual_write)
  end

  defp set_configured(pipeline, events, dual_write) do
    assert :ok = Settings.set(@pipeline, pipeline)
    assert :ok = Settings.set(@events, events)
    assert :ok = Settings.set(@dual_write, dual_write)
  end

  defp restore_application_env(key, {:ok, value}) do
    Application.put_env(:backplane_memory, key, value)
  end

  defp restore_application_env(key, :error) do
    Application.delete_env(:backplane_memory, key)
  end
end
