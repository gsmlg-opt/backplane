defmodule Backplane.HostAgent.Memory.IntegrationPluginContractTest do
  use ExUnit.Case, async: true

  @integrations_root Path.expand("../../../../../../integrations/memory", __DIR__)

  @tag timeout: 20_000
  test "Hermes packaged provider uses bound recall source and durable capture contracts" do
    python = System.find_executable("python3") || flunk("python3 is required")
    source = Path.join([@integrations_root, "hermes", "__init__.py"])

    script = ~S'''
    import contextlib, hashlib, importlib.util, io, json, os, sys, tempfile, threading, time
    from pathlib import Path
    from urllib.error import URLError
    from urllib.parse import urlparse
    from unittest.mock import patch

    spec = importlib.util.spec_from_file_location("backplane_memory_hermes", sys.argv[1])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = plugin
    spec.loader.exec_module(plugin)
    sys.path.insert(0, str(Path(sys.argv[1]).parent.parent / "tests"))
    from test_hermes_runtime import load_pinned_scrubber
    scrubber = load_pinned_scrubber()
    calls, calls_lock = [], threading.Lock()
    capture_entered, capture_release, capture_returned = (threading.Event() for _ in range(3))
    access_id = "74be1bcf-a924-4fb4-9a3a-8cddf8d857b7"
    binding = {"access_id": access_id, "authority_version": 1, "partition": {
        "memory_space_id": "1123e91e-203b-47a4-9d2f-dcb0317094cd",
        "scope": "host-bound-fixture", "namespace": "private"}}
    fingerprint = hashlib.sha256(plugin.canonical_json(binding).encode()).hexdigest()
    capabilities = {"protocol": "memory_sources.v1", "supported": True, "ready": True,
        "negotiated": ["memory_sources.v1", "hermes_capture.v1"],
        "binding": binding, "binding_fingerprint": fingerprint, "capture_ready": True,
        "capture_binding": binding, "capture_binding_fingerprint": fingerprint}

    class Response:
        def __init__(self, body): self.body = body
        def __enter__(self): return self
        def __exit__(self, *_args): return False
        def read(self, _limit): return json.dumps(self.body).encode()

    def urlopen(request, timeout):
        body = json.loads(request.data.decode())
        path = urlparse(request.full_url).path
        with calls_lock:
            calls.append({"url": request.full_url, "method": request.method, "body": body, "timeout": timeout})
        if path.endswith("/source_capabilities"):
            return Response({"ok": True, "result": capabilities})
        if path.endswith("/recall"):
            return Response({"ok": True, "result": {"results": [{
                "canonical_id": "context-fixture", "revision": 7,
                "content": "prior memory query fact", "policy_version": "current_context.v1",
                "lifecycle_state": "active", "effective_support": True,
                "support_complete": True, "independent_support": True,
                "source_refs": [], "trust": "candidate_inference",
                "expires_at": None, "valid_until": None}]}})
        if path.endswith("/remember"):
            return Response({"ok": True, "result": {"success": True}})
        if path.endswith("/source_mutate") or path.endswith("/source_reconcile"):
            return Response({"ok": True, "result": {"protocol": "memory_sources.v1",
                "event_id": body["event_id"], "status": "committed", "outcome": "applied",
                "authority": "canonical", "consistency": "canonical"}})
        if path == "/capture/v1/status":
            return Response({"ok": True, "result": {"protocol": "hermes_capture.v1",
                "items": [{"event_id": event, "status": "canonical_committed"}
                    for event in body["event_ids"]]}})
        if path.startswith("/capture/v1/hooks/hermes/"):
            if path.endswith("/message"):
                capture_entered.set()
                if not capture_release.wait(timeout=2):
                    raise AssertionError("capture release deadline exceeded")
                capture_returned.set()
            return Response({"ok": True, "status": "accepted", "event_id": body["event_id"]})
        raise AssertionError("unexpected request path")

    with tempfile.TemporaryDirectory(prefix="backplane-hermes-contract-") as temporary:
        home = Path(temporary).resolve()
        (home / "memories").mkdir()
        for name in ("MEMORY.md", "USER.md"):
            (home / "memories" / name).write_text("", encoding="utf-8")
        (home / "backplane-memory.json").write_text(json.dumps({
            "url": "http://127.0.0.1:4222", "agent_id": "hermes test",
            "memory_access_id": access_id}), encoding="utf-8")
        provider = plugin.BackplaneMemoryProvider()
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(plugin, "urlopen", side_effect=urlopen), \
             patch.object(plugin, "_load_egress_scrubber", return_value=scrubber), \
             patch("socket.socket.connect", side_effect=AssertionError("network forbidden")):
            try:
                provider.initialize("session-1", hermes_home=str(home), cwd=str(home / "checkout"))
                initial = provider.flush(timeout=3, canonical=True)
                assert initial["success"], initial
                with patch.object(plugin, "_post", side_effect=AssertionError("local API must not send")):
                    available = provider.is_available()
                    prompt = provider.system_prompt_block()
                provider.queue_prefetch("memory query")
                deadline = time.monotonic() + 3
                recall = ""
                while time.monotonic() < deadline and not recall:
                    recall = provider.prefetch("memory query")
                    if not recall:
                        time.sleep(0.01)
                assert recall, "prefetch deadline exceeded"
                saved = json.loads(provider.handle_tool_call("memory_save", {
                    "content": "remember me", "tags": ["m18"]}))
                (home / "memories" / "MEMORY.md").write_text(
                    "native fact API_KEY=synthetic-private-secret-value", encoding="utf-8")
                provider.on_memory_write("add", "memory", "native fact API_KEY=synthetic-private-secret-value",
                    metadata={"session_id": "session-native", "role": "user"})
                source_settled = provider.flush(timeout=3, canonical=True)
                assert source_settled["success"], source_settled

                started = time.monotonic()
                provider.sync_turn("actual user", "actual assistant", session_id="session-2", messages=[
                    {"role": "user", "content": "actual user", "message_uid": "actual-user-uid"},
                    {"role": "assistant", "content": "actual assistant", "message_uid": "actual-assistant-uid"}],
                    turn_author={"name": "actual speaker"})
                elapsed_ms = (time.monotonic() - started) * 1000
                with provider._journal.lock:
                    durable = [json.loads(row[0]) for row in provider._journal.db.execute(
                        "SELECT payload FROM delivery WHERE path='/capture/v1/hooks/hermes/message'")]
                capture_blocked = capture_entered.wait(timeout=1) and not capture_returned.is_set()
                capture_release.set()
                settled = provider.flush(timeout=3, canonical=True)
                journal_owned = provider._home == home.resolve() and provider._journal.path.is_relative_to(home)
            finally:
                capture_release.set()
                provider.shutdown()
            shutdown = provider.delivery_status()

    warnings = io.StringIO()
    with patch.object(plugin, "urlopen", side_effect=URLError("private-secret")), \
         patch("socket.socket.connect", side_effect=AssertionError("network forbidden")), \
         contextlib.redirect_stderr(warnings):
        failure = plugin._post("http://127.0.0.1:4222", "hermes test", "recall", {"query": "private-secret"})

    print(json.dumps({"calls": calls, "available": available, "prompt": prompt,
        "recall": recall, "saved": saved, "elapsed_ms": elapsed_ms,
        "durable": durable, "capture_blocked": capture_blocked, "settled": settled,
        "shutdown": shutdown, "journal_owned": journal_owned,
        "failure": failure, "warnings": warnings.getvalue()}))
    '''

    {output, 0} = System.cmd(python, ["-B", "-c", script, source], stderr_to_stdout: true)
    refute output =~ "private-secret"
    result = Jason.decode!(output)

    assert result["available"]
    refute result["prompt"] =~ "prior memory query fact"

    assert result["recall"] ==
             "- [candidate inference; context-fixture; revision 7] prior memory query fact"

    assert result["saved"] == %{"success" => true}
    assert result["elapsed_ms"] < 100
    assert result["capture_blocked"]
    assert result["journal_owned"]
    assert result["settled"]["success"]
    assert result["settled"]["canonical_committed"] > 0
    assert result["shutdown"]["worker_alive"] == false
    assert result["failure"] == %{"ok" => false, "error" => "request_failed"}
    assert result["warnings"] =~ "request_failed"

    calls = result["calls"]
    access_id = "74be1bcf-a924-4fb4-9a3a-8cddf8d857b7"
    recall_calls = Enum.filter(calls, &String.ends_with?(&1["url"], "/call/recall"))
    assert recall_calls != []

    for recall <- recall_calls do
      assert recall["url"] == "http://127.0.0.1:4222/memory/hermes%20test/call/recall"

      assert recall["body"] == %{
               "query" => "memory query",
               "limit" => 5,
               "token_budget" => 1200,
               "memory_access_id" => access_id
             }
    end

    assert [remember] = Enum.filter(calls, &String.ends_with?(&1["url"], "/call/remember"))
    assert remember["url"] == "http://127.0.0.1:4222/memory/hermes%20test/call/remember"

    assert remember["body"] == %{
             "content" => "remember me",
             "type" => "semantic",
             "tags" => ["m18"],
             "session_id" => "session-1",
             "memory_access_id" => access_id
           }

    assert [capabilities] =
             Enum.filter(calls, &String.ends_with?(&1["url"], "/call/source_capabilities"))

    assert capabilities["body"] == %{"memory_access_id" => access_id}
    assert [mutation] = Enum.filter(calls, &String.ends_with?(&1["url"], "/call/source_mutate"))
    source = mutation["body"]
    assert source["protocol"] == "memory_sources.v1"
    assert source["operation"] == "upsert"
    assert source["type"] == "semantic"
    assert source["memory_access_id"] == access_id
    assert source["source"]["integration"] == "hermes"
    assert source["source"]["target"] == "memory"
    assert {:ok, _} = Ecto.UUID.cast(source["source"]["installation_id"])
    assert {:ok, _} = Ecto.UUID.cast(source["source"]["profile_id"])
    assert {:ok, _} = Ecto.UUID.cast(source["entry_id"])
    assert {:ok, _} = Ecto.UUID.cast(source["event_id"])
    assert source["revision"] > 0
    assert source["content"] =~ "native fact"
    refute Jason.encode!(calls) =~ "synthetic-private-secret-value"
    assert source["provenance"]["session_id"] == "session-native"
    assert source["provenance"]["role"] == "user"
    assert String.ends_with?(source["provenance"]["cwd"], "/checkout")

    assert [%{"role" => "user"} = user, %{"role" => "assistant"} = assistant] =
             Enum.sort_by(result["durable"], & &1["source_sequence"])

    assert user["message_uid"] == "actual-user-uid"
    assert user["content"] == "actual user"
    assert user["author"] == %{"name" => "actual speaker"}
    assert assistant["message_uid"] == "actual-assistant-uid"
    assert assistant["content"] == "actual assistant"

    capture_calls = Enum.filter(calls, &String.contains?(&1["url"], "/capture/v1/hooks/hermes/"))
    assert Enum.any?(capture_calls, &String.ends_with?(&1["url"], "/session-start"))
    assert Enum.any?(calls, &String.ends_with?(&1["url"], "/capture/v1/status"))

    for message <- [user, assistant] do
      assert message["protocol"] == "hermes_capture.v1"
      assert message["session_id"] == "session-2"
      assert message["agent_id"] == "hermes test"
      assert message["source_revision"] == 1
      assert message["completeness"]["truncated"] == false
      assert {:ok, _} = Ecto.UUID.cast(message["event_id"])
      assert Enum.any?(capture_calls, &(&1["body"] == message))
    end

    for call <- calls do
      assert call["method"] == "POST"
      assert call["timeout"] == 2
      refute Map.has_key?(call["body"], "scope")
      refute Map.has_key?(call["body"], "host_id")

      if String.contains?(call["url"], "/capture/"),
        do: refute(Map.has_key?(call["body"], "memory_access_id"))
    end
  end

  test "packaged clients preserve bound scope and expose redacted request failures" do
    python = System.find_executable("python3") || flunk("python3 is required")
    node = System.find_executable("node") || flunk("node is required")

    for {runtime, args} <- [
          {python, [Path.join([@integrations_root, "tests", "test_hermes.py"])]},
          {node, ["--test", Path.join([@integrations_root, "tests", "test_openclaw.mjs"])]}
        ] do
      {output, status} = System.cmd(runtime, args, stderr_to_stdout: true)
      assert status == 0, output
    end
  end

  test "OpenClaw packaged plugin uses exact protocol, fail-open privacy, and async capture" do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";

    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const handlers = {};
    const warnings = [];
    const calls = [];
    const api = {
      pluginConfig: { enabled: true, agent_id: "openclaw test", fallback_on_error: true, timeout_ms: 50 },
      logger: { warn: (message) => warnings.push(message) },
      on: (name, handler) => { handlers[name] = handler; },
      registerMemoryCapability: () => {},
    };
    plugin.register(api);

    globalThis.fetch = async (url, options) => {
      calls.push({ url, method: options.method, body: JSON.parse(options.body) });
      if (url.endsWith("/recall")) {
        return { ok: true, json: async () => ({ ok: true, result: { results: [{ content: "prior fact", scope: "project" }] } }) };
      }
      return { ok: true, json: async () => ({ ok: true, result: { success: true } }) };
    };

    const context = await handlers.before_agent_start({ prompt: "memory query" });
    await handlers.agent_end({
      success: true,
      sessionId: "session-1",
      messages: [
        { role: "user", content: "remember this" },
        { role: "assistant", content: "done" },
      ],
    });
    await new Promise((resolve) => setTimeout(resolve, 0));

    globalThis.fetch = async () => { throw new Error("private-secret"); };
    await handlers.before_agent_start({ prompt: "private-secret" });

    globalThis.fetch = () => new Promise(() => {});
    const started = Date.now();
    const completed = await Promise.race([
      handlers.agent_end({
        success: true,
        sessionId: "session-2",
        messages: [
          { role: "user", content: "slow user" },
          { role: "assistant", content: "slow assistant" },
        ],
      }).then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 75)),
    ]);

    console.log(JSON.stringify({ calls, context, warnings, completed, elapsed_ms: Date.now() - started }));
    '''

    {output, 0} = System.cmd(node, ["--input-type=module", "-e", script, source])
    result = Jason.decode!(output)

    assert result["context"]["prependContext"] =~ "prior fact"
    assert result["completed"] == true
    assert result["elapsed_ms"] < 75
    refute Enum.any?(result["warnings"], &String.contains?(&1, "private-secret"))

    assert [recall, remember] = result["calls"]
    assert recall["url"] == "http://127.0.0.1:4222/memory/openclaw%20test/call/recall"
    assert recall["method"] == "POST"
    assert recall["body"] == %{"query" => "memory query", "limit" => 5}

    assert remember["url"] ==
             "http://127.0.0.1:4222/memory/openclaw%20test/call/remember"

    assert remember["body"]["content"] == "User: remember this\n\nAssistant: done"
    assert remember["body"]["type"] == "episodic"
    assert remember["body"]["session_id"] == "session-1"
    assert remember["body"]["metadata"]["source"] == "openclaw.agent_end"
  end

  test "OpenClaw detached capture handles rejection when fallback is disabled" do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";

    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const handlers = {};
    const warnings = [];
    plugin.register({
      pluginConfig: { enabled: true, fallback_on_error: false, timeout_ms: 50 },
      logger: { warn: (message) => warnings.push(message) },
      on: (name, handler) => { handlers[name] = handler; },
      registerMemoryCapability: () => {},
    });

    globalThis.fetch = async () => { throw new TypeError("private-secret"); };
    await handlers.agent_end({
      success: true,
      sessionId: "session-rejected",
      messages: [
        { role: "user", content: "remember this" },
        { role: "assistant", content: "done" },
      ],
    });
    await new Promise((resolve) => setTimeout(resolve, 25));
    console.log(JSON.stringify({ warnings }));
    '''

    {output, 0} =
      System.cmd(
        node,
        ["--unhandled-rejections=strict", "--input-type=module", "-e", script, source],
        stderr_to_stdout: true
      )

    refute output =~ "private-secret"
    assert %{"warnings" => [warning]} = Jason.decode!(output)
    assert warning =~ "TypeError"
  end
end
