defmodule Backplane.HostAgent.CaptureRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.RecallCache
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

  defmodule LifecycleProxy do
    def call("lifecycle_context", args, opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:lifecycle_context, args, opts})

      case :persistent_term.get({__MODULE__, :result}) do
        {:sleep, milliseconds, result} ->
          Process.sleep(milliseconds)
          result

        result ->
          result
      end
    end
  end

  setup %{tmp_dir: dir} do
    spool =
      start_supervised!(
        {Spool,
         database: Path.join(dir, "capture.db"),
         name: nil,
         id: {:capture_router_spool, System.unique_integer([:positive])}}
      )

    cache =
      start_supervised!(
        {RecallCache,
         name: nil, max_entries: 8, max_bytes: 100_000, ttl_ms: 60_000, id: make_ref()}
      )

    runtime = %{
      host_id: "trusted-host",
      spool: spool,
      spool_module: Spool,
      recall_cache: cache,
      memory_proxy_module: LifecycleProxy,
      config: %{inject_context: false, context_timeout_ms: 100}
    }

    Application.put_env(:backplane_host_agent, :capture_runtime, runtime)
    :persistent_term.put({LifecycleProxy, :owner}, self())
    :persistent_term.put({LifecycleProxy, :result}, {:error, :not_connected})

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :capture_runtime)
      :persistent_term.erase({LifecycleProxy, :owner})
      :persistent_term.erase({LifecycleProxy, :result})
    end)

    {:ok, spool: spool, cache: cache}
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

  test "durably captures before returning live lifecycle context", %{spool: spool} do
    enable_context(100)

    :persistent_term.put(
      {LifecycleProxy, :result},
      {:ok, live_context()}
    )

    response = post_hook("claude_code", "session-start", fixture("session-start"))
    assert response.status == 202

    assert %{"lifecycle_context" => %{"context" => "remember this", "cached" => false}} =
             Jason.decode!(response.resp_body)

    assert_receive {:lifecycle_context,
                    %{
                      "kind" => "session_start",
                      "session_id" => "session-1",
                      "project" => "/workspace/backplane"
                    }, opts}

    assert opts[:agent_id] == "claude-main"
    assert opts[:timeout] == 100
    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "disabled capture context never calls the hub" do
    assert %{status: 202} = post_hook("claude_code", "session-start", fixture("session-start"))
    refute_receive {:lifecycle_context, _, _}
  end

  test "timeout stays bounded, returns no context, and leaves the event spooled", %{spool: spool} do
    enable_context(35)
    :persistent_term.put({LifecycleProxy, :result}, {:sleep, 500, {:ok, live_context()}})

    started = System.monotonic_time(:millisecond)
    response = post_hook("claude_code", "pre-compact", fixture("pre-compact"))
    elapsed = System.monotonic_time(:millisecond) - started

    assert response.status == 202
    refute Map.has_key?(Jason.decode!(response.resp_body), "lifecycle_context")
    assert elapsed < 200
    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "transport unavailability uses a kind-isolated visibly stale cache", %{cache: cache} do
    enable_context(100)

    assert :ok =
             RecallCache.put(
               cache,
               {"session_start", "/workspace/backplane", "claude-main"},
               live_context()
             )

    :persistent_term.put({LifecycleProxy, :result}, {:error, :not_connected})
    response = post_hook("claude_code", "session-start", fixture("session-start"))

    assert %{
             "lifecycle_context" => %{
               "context" => context,
               "source_revision" => "sha256:live",
               "cached" => true,
               "stale" => true,
               "age_seconds" => age
             }
           } = Jason.decode!(response.resp_body)

    assert context =~ "Cached memory context (stale)"
    assert context =~ "sha256:live"
    assert is_integer(age)

    new_session = fixture("session-start") |> Map.put("session_id", "session-2")
    response = post_hook("claude_code", "session-start", new_session)
    assert get_in(Jason.decode!(response.resp_body), ["lifecycle_context", "cached"]) == true

    response = post_hook("claude_code", "pre-compact", fixture("pre-compact"))
    refute Map.has_key?(Jason.decode!(response.resp_body), "lifecycle_context")
  end

  test "semantic or authorization errors never use cached context", %{cache: cache} do
    enable_context(100)
    key = {"session_start", "/workspace/backplane", "claude-main"}
    assert :ok = RecallCache.put(cache, key, live_context())

    for error <- [%{"code" => "unauthorized"}, {:validation, :project}] do
      :persistent_term.put({LifecycleProxy, :result}, {:error, error})
      response = post_hook("claude_code", "session-start", fixture("session-start"))
      refute Map.has_key?(Jason.decode!(response.resp_body), "lifecycle_context")
    end
  end

  test "only whitelisted channel transport exits use cached context", %{cache: cache} do
    enable_context(100)
    key = {"session_start", "/workspace/backplane", "claude-main"}
    assert :ok = RecallCache.put(cache, key, live_context())

    for error <- [
          {:channel_exit, :unauthorized},
          {:channel_exit, {:shutdown, :unauthorized}},
          {:channel_exit, :unknown_failure}
        ] do
      :persistent_term.put({LifecycleProxy, :result}, {:error, error})
      response = post_hook("claude_code", "session-start", fixture("session-start"))
      refute Map.has_key?(Jason.decode!(response.resp_body), "lifecycle_context")
    end

    :persistent_term.put({LifecycleProxy, :result}, {:error, {:channel_exit, :closed}})
    response = post_hook("claude_code", "session-start", fixture("session-start"))

    assert get_in(Jason.decode!(response.resp_body), ["lifecycle_context", "cached"]) == true
  end

  test "incomplete, malformed, expired, or incoherent live metadata is never injected or cached",
       %{cache: cache} do
    enable_context(100)
    now = DateTime.utc_now()

    invalid_results = [
      Map.delete(live_context(), "source_revision"),
      %{live_context() | "generated_at" => "not-a-timestamp"},
      %{
        live_context()
        | "generated_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(now)
      },
      %{
        live_context()
        | "generated_at" => now |> DateTime.add(-120, :second) |> DateTime.to_iso8601(),
          "expires_at" => now |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      }
    ]

    Enum.each(invalid_results, fn result ->
      :persistent_term.put({LifecycleProxy, :result}, {:ok, result})
      response = post_hook("claude_code", "session-start", fixture("session-start"))
      assert response.status == 202
      refute Map.has_key?(Jason.decode!(response.resp_body), "lifecycle_context")
    end)

    assert :miss =
             RecallCache.get(cache, {"session_start", "/workspace/backplane", "claude-main"})
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

  defp enable_context(timeout) do
    runtime = Application.fetch_env!(:backplane_host_agent, :capture_runtime)

    Application.put_env(
      :backplane_host_agent,
      :capture_runtime,
      put_in(runtime, [:config], %{inject_context: true, context_timeout_ms: timeout})
    )
  end

  defp live_context do
    now = DateTime.utc_now()

    %{
      "kind" => "session_start",
      "context" => "remember this",
      "source_revision" => "sha256:live",
      "generated_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> DateTime.add(900, :second) |> DateTime.to_iso8601(),
      "cached" => false,
      "stale" => false
    }
  end
end
