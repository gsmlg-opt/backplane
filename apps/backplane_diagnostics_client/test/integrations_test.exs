defmodule Backplane.DiagnosticsClient.IntegrationsTest do
  use ExUnit.Case, async: false

  alias Backplane.DiagnosticsClient.{Context, Receipt, Reporter}
  alias Backplane.DiagnosticsClient.Integrations.{Capture, Phoenix, Runtime}
  alias Backplane.DiagnosticsClient.Integrations.Logger, as: DiagnosticsLogger
  alias Backplane.DiagnosticsClient.Integrations.Task, as: DiagnosticsTask

  setup do
    parent = self()

    start_supervised!(
      {Reporter,
       [
         application: "test",
         source_id: "test-source",
         interval_ms: 15,
         send_batch: fn batch ->
           Enum.each(batch["events"], &send(parent, {:event, &1["event"]}))

           {:ok,
            Receipt.response(
              :local,
              batch["batch_id"],
              Enum.map(batch["events"], &Receipt.result(&1, "stored"))
            )}
         end
       ]}
    )

    :ok
  end

  test "captures matching Phoenix and Logger observations without inspecting exception arguments" do
    assert :ok = Phoenix.attach(__MODULE__)
    on_exit(fn -> Phoenix.detach(__MODULE__) end)

    reason = %RuntimeError{message: "synthetic secret from request body"}

    frames = [
      {__MODULE__, :example, ["private stack argument"], [file: ~c"test/fixture.exs", line: 12]}
    ]

    request = "request-1"

    :telemetry.execute([:phoenix, :router_dispatch, :exception], %{duration: 15}, %{
      kind: :error,
      reason: reason,
      stacktrace: frames,
      conn: %{resp_headers: [{"x-request-id", request}], params: %{"prompt" => "secret"}}
    })

    assert :ok =
             DiagnosticsLogger.log(
               %{meta: %{pid: self(), request_id: request, crash_reason: {reason, frames}}},
               %{config: []}
             )

    assert_receive {:event, first}, 500
    assert_receive {:event, second}, 500
    assert first["event_id"] != second["event_id"]
    assert first["correlation"]["occurrence_hint"] == second["correlation"]["occurrence_hint"]
    assert is_binary(first["correlation"]["occurrence_hint"])
    assert first["correlation"]["request_id"] == request
    assert [frame] = get_in(first, ["evidence", "exception", "stack"])
    assert %{"arity" => 1, "file" => "test/fixture.exs", "line" => 12} = frame

    for event <- [first, second] do
      encoded = Formata.JSON.encode!(event)
      refute encoded =~ "synthetic secret"
      refute encoded =~ "private stack argument"
      refute encoded =~ "prompt"
    end
  end

  test "automatically observes a crashed Task and preserves parallel run context" do
    assert :ok = DiagnosticsLogger.attach(__MODULE__)
    on_exit(fn -> DiagnosticsLogger.detach(__MODULE__) end)
    supervisor = start_supervised!(Task.Supervisor)

    crashing =
      Context.with_context(%{"subject" => %{"run_id" => "failed-run"}}, fn ->
        fun = DiagnosticsTask.with_context(fn -> raise "controlled task crash" end)
        Task.Supervisor.async_nolink(supervisor, fun)
      end)

    other =
      Context.with_context(%{"subject" => %{"run_id" => "healthy-run"}}, fn ->
        Task.Supervisor.async_nolink(
          supervisor,
          DiagnosticsTask.with_context(fn -> Context.current() end)
        )
      end)

    assert %{"subject" => %{"run_id" => "healthy-run"}} = Task.await(other)
    assert_receive {:DOWN, _, :process, pid, reason}, 500
    assert pid == crashing.pid
    assert :enqueued = DiagnosticsTask.failed(pid, reason, subject: %{"run_id" => "failed-run"})

    assert_receive {:event,
                    %{"event_type" => "exception", "subject" => %{"run_id" => "failed-run"}} =
                      logged},
                   500

    assert_receive {:event, %{"event_type" => "worker_exit"} = down}, 500
    assert logged["correlation"]["occurrence_hint"] == down["correlation"]["occurrence_hint"]
    assert logged["quality"]["stack"] == "available"
    assert :ignored = DiagnosticsTask.failed(self(), {:shutdown, :normal}, [])
  end

  test "captures handled Runtime errors with bounded evidence and skips expected flow" do
    assert :ignored = Runtime.error(%{class: :cancelled, cause: :normal}, "tool")

    assert :enqueued =
             Runtime.error(%{class: :malformed_result, cause: {:invalid_shape, []}}, "tool")

    assert_receive {:event,
                    %{"event_type" => "handled_error", "quality" => %{"stack" => "unavailable"}} =
                      event},
                   500

    assert get_in(event, ["evidence", "exception", "code"]) == "malformed_result"
    assert :ignored = Capture.report("exception", :exit, :normal, [])
  end
end
