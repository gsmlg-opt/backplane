defmodule Backplane.HostAgent.CaptureRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.MemoryRouter

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  @mappings %{
    "session-start" => "agent.session.started",
    "user-prompt-submit" => "agent.prompt.submitted",
    "post-tool-use" => "agent.tool.completed",
    "post-tool-use-failure" => "agent.tool.failed",
    "pre-compact" => "agent.context.pre_compact",
    "subagent-start" => "agent.subagent.started",
    "subagent-stop" => "agent.subagent.stopped",
    "stop" => "agent.session.stopped",
    "session-end" => "agent.session.ended",
    "post-commit" => "git.commit.created"
  }

  defmodule FailingSpool do
    def append(_spool, _envelope), do: {:error, :disk_full}
  end

  setup %{tmp_dir: dir} do
    spool =
      start_supervised!(
        {Spool,
         database: Path.join(dir, "capture.db"),
         name: nil,
         id: {:capture_router_spool, System.unique_integer([:positive])}}
      )

    runtime = %{
      host_id: "trusted-host",
      spool: spool,
      spool_module: Spool
    }

    Application.put_env(:backplane_host_agent, :capture_runtime, runtime)

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :capture_runtime)
    end)

    {:ok, spool: spool}
  end

  test "accepts and durably maps all ten hooks", %{spool: spool} do
    Enum.each(@mappings, fn {hook, _event_type} ->
      conn = post_hook("claude_code", hook, fixture(hook))
      assert conn.status == 202
      assert %{"ok" => true, "status" => "accepted"} = Jason.decode!(conn.resp_body)
    end)

    events = Spool.next_batch(spool, 20, 1_000_000)

    assert Map.new(events, &{&1["payload"]["hook"], &1["event_type"]}) == @mappings
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..10)
  end

  test "accepts Cursor hooks end to end", %{spool: spool} do
    body = %{
      "conversation_id" => "conv-1",
      "generation_id" => "gen-1",
      "workspace_roots" => ["/w/a"],
      "prompt" => "hello"
    }

    assert %{status: 202} = post_hook("cursor", "beforeSubmitPrompt", body)
    assert [event] = Spool.next_batch(spool, 10, 100_000)
    assert event["event_type"] == "agent.prompt.submitted"
    assert event["integration"] == "cursor"
    assert event["session_id"] == "conv-1"
  end

  test "uses trusted runtime host identity and filters caller payload before persistence", %{
    spool: spool
  } do
    input =
      fixture("user-prompt-submit")
      |> Map.merge(%{
        "host_id" => "spoofed-host",
        "prompt" => "use sk-secret-token and <private>hidden</private>"
      })

    assert %{status: 202} = post_hook("claude_code", "user-prompt-submit", input)
    assert [event] = Spool.next_batch(spool, 10, 100_000)
    assert event["host_id"] == "trusted-host"
    refute event["payload"]["source"]["prompt"] =~ "sk-secret-token"
    refute event["payload"]["source"]["prompt"] =~ "hidden"
    refute Map.has_key?(event["payload"]["source"], "host_id")
  end

  test "returns duplicate success without adding a second spool row", %{spool: spool} do
    body = fixture("post-tool-use")

    assert %{"status" => "accepted", "event_id" => event_id} =
             post_hook("claude_code", "post-tool-use", body).resp_body |> Jason.decode!()

    assert %{"status" => "duplicate", "event_id" => ^event_id} =
             post_hook("claude_code", "post-tool-use", body).resp_body |> Jason.decode!()

    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "Hermes capture status distinguishes durable local acceptance canonical ACK and rejection",
       %{spool: spool} do
    id = "2699493c-6347-4138-baba-8b09393a8500"

    body = %{
      "protocol" => "hermes_capture.v1",
      "event_id" => id,
      "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
      "profile_id" => "primary",
      "source_sequence" => 1,
      "session_id" => "actual-session",
      "occurred_at" => "2026-10-24T01:00:00Z",
      "captured_at" => "2026-10-24T01:00:00Z",
      "role" => "assistant",
      "content" => "candidate statement",
      "agent_id" => "Rikka"
    }

    assert %{status: 202} = post_hook("hermes", "message", body)

    request = fn ids ->
      conn(:post, "/capture/v1/status", Jason.encode!(%{"event_ids" => ids}))
      |> put_req_header("content-type", "application/json")
      |> MemoryRouter.call(MemoryRouter.init([]))
    end

    assert %{
             "ok" => true,
             "result" => %{
               "protocol" => "hermes_capture.v1",
               "items" => [%{"event_id" => ^id, "status" => "host_accepted"}]
             }
           } = request.([id]).resp_body |> Jason.decode!()

    assert :ok = Spool.acknowledge(spool, [id])

    assert %{"result" => %{"items" => [%{"status" => "canonical_committed"}]}} =
             request.([id]).resp_body |> Jason.decode!()

    other = "34aa960d-50c9-4086-ad8e-06f9a340b03f"

    assert %{status: 202} =
             post_hook("hermes", "message", %{body | "event_id" => other, "source_sequence" => 2})

    assert :ok = Spool.reject(spool, other, :unauthorized, true)

    assert %{
             "result" => %{"items" => [%{"status" => "rejected", "error_code" => "unauthorized"}]}
           } = request.([other]).resp_body |> Jason.decode!()

    assert %{status: 400} = request.(["bad-id"])
  end

  test "does not collapse identical hook calls that have no source identity", %{spool: spool} do
    body = fixture("user-prompt-submit") |> Map.drop(["source_event_id", "tool_use_id"])

    assert %{"status" => "accepted", "event_id" => first_id} =
             post_hook("claude_code", "user-prompt-submit", body).resp_body |> Jason.decode!()

    assert %{"status" => "accepted", "event_id" => second_id} =
             post_hook("claude_code", "user-prompt-submit", body).resp_body |> Jason.decode!()

    assert first_id != second_id
    assert %{pending_depth: 2} = Spool.stats(spool)
  end

  test "returns 400 for unsupported integrations, hooks, and malformed payloads" do
    assert %{status: 202} = post_hook("codex", "session-start", fixture("session-start"))
    assert %{status: 400} = post_hook("opencode", "session-start", fixture("session-start"))
    assert %{status: 400} = post_hook("claude_code", "unknown", fixture("unknown"))
    assert %{status: 400} = post_hook("claude_code", "session-start", %{})
    assert %{status: 400} = post_hook("claude_code", "session-start", [])
  end

  test "returns 503 when durable append is unavailable" do
    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: "trusted-host",
      spool: :unavailable,
      spool_module: FailingSpool
    })

    conn = post_hook("claude_code", "session-start", fixture("session-start"))
    assert conn.status == 503

    assert %{"ok" => false, "error" => "capture persistence unavailable"} =
             Jason.decode!(conn.resp_body)
  end

  test "preserves legacy memory routes" do
    conn = post_json("/memory/local/call/not-a-method", %{})
    assert conn.status == 404
    assert %{"error" => "unknown method: not-a-method"} = Jason.decode!(conn.resp_body)
  end

  defp post_hook(integration, hook, body) do
    post_json("/capture/v1/hooks/#{integration}/#{hook}", body)
  end

  defp post_json(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> then(&MemoryRouter.call(&1, MemoryRouter.init([])))
  end

  defp fixture(hook) do
    %{
      "hook" => hook,
      "session_id" => "session-1",
      "agent_id" => "claude-main",
      "host_id" => "spoofed-host",
      "source_event_id" => "source-#{hook}",
      "occurred_at" => "2026-08-04T01:00:00Z",
      "cwd" => "/workspace/backplane",
      "tool_use_id" => "tool-1",
      "prompt" => "capture this prompt"
    }
  end
end
