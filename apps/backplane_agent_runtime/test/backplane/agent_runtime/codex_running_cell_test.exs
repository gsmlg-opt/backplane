defmodule Backplane.AgentRuntime.CodexRunningCellTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Error, Codex.CodeMode, Codex.ResourceRegistry}

  setup do
    registry = start_supervised!(ResourceRegistry)
    opts = [dispatcher: fn _, _ -> {:ok, :unused} end, timeout: 2_000, yield_time_ms: 20]
    %{registry: registry, opts: opts}
  end

  test "time slices return incremental output and a completion closes the handle", %{
    registry: registry,
    opts: opts
  } do
    code = "text('first'); await new Promise(r => setTimeout(r, 180)); text('last'); return 42;"

    assert {:ok, %{status: :yielded, handle: handle, output: first}} =
             CodeMode.execute(registry, "a", code, opts)

    Process.sleep(350)

    assert {:ok, %{status: :completed, value: 42, output: last}} =
             CodeMode.resume(registry, handle, nil, owner: "a", yield_time_ms: 50)

    assert Enum.map(first ++ last, & &1["text"]) == ["first", "last"]

    assert {:error, %Error{class: :not_found}} =
             CodeMode.resume(registry, handle, nil, owner: "a")
  end

  test "tools and raw input use metadata; detached calls wait for current authority", %{
    registry: registry,
    opts: opts
  } do
    parent = self()
    old = fn _, _ -> flunk("detached cell used old dispatcher") end

    opts =
      Keyword.merge(opts,
        dispatcher: old,
        tools: [%{name: "mcp::raw", description: "Raw tool", input_kind: :custom}]
      )

    code =
      "await new Promise(r => setTimeout(r, 150)); text(ALL_TOOLS[0].description); return await tools.mcp__raw('patch');"

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(registry, "a", code, opts)

    Process.sleep(220)

    current = fn request, context ->
      send(parent, {:dispatched, request, context})
      {:ok, 9}
    end

    assert {:ok, %{status: :completed, value: 9}} =
             CodeMode.resume(registry, handle, nil,
               owner: "a",
               dispatcher: current,
               execution_context: %{run_id: "a", owner_id: "a", revision: 2},
               yield_time_ms: 100
             )

    assert_receive {:dispatched, %{input_kind: :custom, raw_input: "patch"}, %{revision: 2}}
  end

  test "state persists between cells and helpers flush on explicit yield", %{
    registry: registry,
    opts: opts
  } do
    opts = Keyword.put(opts, :yield_time_ms, 1_000)

    assert {:ok, %{status: :completed}} =
             CodeMode.execute(
               registry,
               "a",
               "store('saved', {n:3}); exit(); throw new Error('unreachable');",
               opts
             )

    code =
      "text(load('saved').n); image({image_url:'data:image/png;base64,AA=='}); audio({audio_url:'data:audio/wav;base64,AA=='}); notify('ready'); await yield_control(); text('continued');"

    assert {:ok, %{status: :yielded, handle: handle, output: output}} =
             CodeMode.execute(registry, "a", code, opts)

    assert Enum.map(output, & &1["type"]) == ["text", "image", "audio", "notification"]

    assert {:ok, %{status: :completed, output: [%{"text" => "continued"}]}} =
             CodeMode.resume(registry, handle, nil, owner: "a")

    assert {:ok, %{value: nil}} =
             CodeMode.execute(registry, "b", "return load('saved') ?? null;", opts)
  end

  test "uncertain nested effects retain their classification", %{registry: registry, opts: opts} do
    opts =
      Keyword.merge(opts,
        yield_time_ms: 1_000,
        dispatcher: fn _, _ -> {:error, Error.new(:unknown_outcome, "uncertain write")} end
      )

    assert {:error, %Error{class: :unknown_outcome}} =
             CodeMode.execute(registry, "a", "await codex.tool('write', {});", opts)
  end

  test "stale timer generations cannot terminate a resumed cell", %{
    registry: registry,
    opts: opts
  } do
    assert {:ok, %{handle: handle}} =
             CodeMode.execute(
               registry,
               "a",
               "await yield_control(); await new Promise(r => setTimeout(r, 80)); return 1;",
               Keyword.put(opts, :yield_time_ms, 1_000)
             )

    assert {:ok, worker} = ResourceRegistry.fetch(registry, handle, "a")
    old = make_ref()
    send(worker, {:deadline, old})

    assert {:ok, %{status: :completed, value: 1}} =
             CodeMode.resume(registry, handle, nil, owner: "a")
  end

  test "stored state is removed on owner death after its last cell completes", %{
    registry: registry,
    opts: opts
  } do
    parent = self()

    owner =
      spawn(fn ->
        result =
          CodeMode.execute(
            registry,
            "ephemeral",
            "store('secret', 7);",
            Keyword.put(opts, :yield_time_ms, 1_000)
          )

        send(parent, {:stored, result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:stored, {:ok, %{status: :completed}}}, 3_000
    assert ResourceRegistry.code_state(registry, "ephemeral") == %{"secret" => 7}
    send(owner, :stop)
    assert_owner_closed(registry, "ephemeral", 100)
  end

  defp assert_owner_closed(registry, owner, attempts) do
    case ResourceRegistry.code_state(registry, owner) do
      {:error, %Error{class: :resource_conflict}} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(5)
        assert_owner_closed(registry, owner, attempts - 1)

      other ->
        flunk("owner state survived death: #{inspect(other)}")
    end
  end
end
