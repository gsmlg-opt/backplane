defmodule Backplane.HostAgent.Memory.IntegrationPluginContractTest do
  use ExUnit.Case, async: true

  @integrations_root Path.expand("../../../../../../integrations/memory", __DIR__)

  @tag timeout: 20_000
  test "Hermes packaged provider uses the global memory tools and durable capture" do
    python = System.find_executable("python3") || flunk("python3 is required")
    source = Path.join([@integrations_root, "hermes", "__init__.py"])

    script = ~S"""
    import contextlib, importlib.util, io, json, logging, os, sys, tempfile, threading, time
    from pathlib import Path
    from urllib.error import URLError
    from urllib.parse import urlparse
    from unittest.mock import patch

    spec = importlib.util.spec_from_file_location("backplane_memory_hermes", sys.argv[1])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = plugin
    spec.loader.exec_module(plugin)
    calls, calls_lock = [], threading.Lock()
    capture_entered, capture_release, capture_returned = (threading.Event() for _ in range(3))
    record = {"id": "mem-1", "kind": "fact", "content": "prior memory query fact", "status": "active",
              "observed_at": "2026-11-09T10:00:00Z",
              "provenance": {"host": "gao-mbp", "agent": "codex", "writer": "agent"}}

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
        if path.endswith("/call/search"):
            return Response({"ok": True, "result": {"results": [record]}})
        if path.endswith("/call/remember"):
            return Response({"ok": True, "result": {**record, "id": "mem-saved", "content": body["content"]}})
        if path == "/capture/v1/status":
            return Response({"ok": True, "result": {"protocol": "hermes_capture.v1",
                "items": [{"event_id": event, "status": "canonical_committed"} for event in body["event_ids"]]}})
        if path.startswith("/capture/v1/hooks/hermes/"):
            if path.endswith("/message"):
                capture_entered.set()
                if not capture_release.wait(timeout=2):
                    raise AssertionError("capture release deadline exceeded")
                capture_returned.set()
            return Response({"ok": True, "status": "accepted", "event_id": body["event_id"]})
        raise AssertionError("unexpected request path " + path)

    warnings = io.StringIO()
    handler = logging.StreamHandler(warnings)
    plugin.logger.addHandler(handler)
    plugin.logger.propagate = False

    with tempfile.TemporaryDirectory(prefix="backplane-hermes-contract-") as temporary:
        home = Path(temporary).resolve()
        (home / "backplane-memory.json").write_text(json.dumps({
            "url": "http://127.0.0.1:4222", "agent_id": "hermes test"}), encoding="utf-8")
        provider = plugin.BackplaneMemoryProvider()
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(plugin, "urlopen", side_effect=urlopen), \
             patch("socket.socket.connect", side_effect=AssertionError("network forbidden")):
            try:
                provider.initialize("session-1", hermes_home=str(home), cwd=str(home / "checkout"))
                with patch.object(plugin, "_post", side_effect=AssertionError("local API must not send")):
                    available = provider.is_available()
                    prompt = provider.system_prompt_block()
                context = provider.prefetch("memory query")
                saved = json.loads(provider.handle_tool_call("memory_remember", {
                    "content": "remember me", "tags": ["m18"]}))
                provider.on_memory_write("add", "memory", "native fact",
                    metadata={"session_id": "session-native"})

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

    with patch.object(plugin, "urlopen", side_effect=URLError("private-secret")), \
         patch("socket.socket.connect", side_effect=AssertionError("network forbidden")):
        failure = plugin._post("http://127.0.0.1:4222", "hermes test", "search", {"query": "private-secret"})

    print(json.dumps({"calls": calls, "available": available, "prompt": prompt,
        "context": context, "saved": saved, "elapsed_ms": elapsed_ms,
        "durable": durable, "capture_blocked": capture_blocked, "settled": settled,
        "shutdown": shutdown, "journal_owned": journal_owned,
        "failure": failure, "warnings": warnings.getvalue()}))
    """

    {output, 0} = System.cmd(python, ["-B", "-c", script, source], stderr_to_stdout: true)
    refute output =~ "private-secret"
    result = Jason.decode!(output)

    assert result["available"]

    assert result["prompt"] ==
             File.read!(Path.join([@integrations_root, "shared", "INSTRUCTIONS.md"]))

    assert result["context"] =~ "prior memory query fact"
    assert result["context"] =~ "host gao-mbp"
    assert result["context"] =~ "agent codex"
    assert result["saved"]["id"] == "mem-saved"
    assert result["elapsed_ms"] < 100
    assert result["capture_blocked"]
    assert result["journal_owned"]
    assert result["settled"]["success"]
    assert result["settled"]["canonical_committed"] > 0
    assert result["shutdown"]["worker_alive"] == false
    assert result["failure"] == %{"ok" => false, "error" => "request_failed"}
    assert result["warnings"] =~ "request_failed"

    calls = result["calls"]
    base = "http://127.0.0.1:4222/memory/hermes%20test/call/"

    assert [search] = Enum.filter(calls, &String.ends_with?(&1["url"], "/call/search"))
    assert search["url"] == base <> "search"
    assert search["body"] == %{"query" => "memory query", "limit" => 8}

    assert [tool, mirrored] = Enum.filter(calls, &String.ends_with?(&1["url"], "/call/remember"))
    assert tool["url"] == base <> "remember"

    assert tool["body"] == %{
             "content" => "remember me",
             "tags" => ["m18"],
             "session_id" => "session-1"
           }

    assert %{
             "content" => "native fact",
             "kind" => "note",
             "writer" => "agent",
             "session_id" => "session-native",
             "request_key" => "hermes:" <> _
           } = mirrored["body"]

    for retired <-
          ~w(source_capabilities source_mutate source_reconcile source_status recall list) do
      refute Enum.any?(calls, &String.ends_with?(&1["url"], "/call/" <> retired))
    end

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
      assert call["timeout"] <= 20
      refute Map.has_key?(call["body"], "scope")
      refute Map.has_key?(call["body"], "host_id")
      refute Map.has_key?(call["body"], "memory_access_id")
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

  test "OpenClaw packaged plugin declares policy-bound hooks, tools, and provider flush" do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";
    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const hooks = {}, registrations = {}, warnings = [];
    plugin.register({
      pluginConfig: { enabled: true, bindings: [{ agent_id: "main", memory_access_id: "11111111-1111-4111-8111-111111111111" }] },
      config: { plugins: { entries: { "backplane-memory": { hooks: { allowConversationAccess: true } } } } },
      logger: { warn: (message) => warnings.push(message) },
      on: (name, _handler, options) => { hooks[name] = options || {}; },
      registerTool: (factory, options) => { registrations.tools = { contextVersion: factory.contextVersion, names: options.names }; },
      registerMemoryCapability: (capability) => { registrations.flush = capability.providerFlushPlanResolver(); registrations.runtime = typeof capability.providerRuntime.open; },
      registerService: (service) => { registrations.service = service.id; },
    });
    console.log(JSON.stringify({ hooks, registrations, warnings }));
    '''

    {output, 0} = System.cmd(node, ["--input-type=module", "-e", script, source])
    result = Jason.decode!(output)

    assert Enum.sort(Map.keys(result["hooks"])) == [
             "agent_end",
             "before_prompt_build",
             "session_end"
           ]

    assert result["hooks"]["before_prompt_build"] == %{"requiresToolAuthority" => true}
    assert result["registrations"]["tools"]["contextVersion"] == 2

    manifest =
      @integrations_root
      |> Path.join("openclaw/openclaw.plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert Enum.sort(result["registrations"]["tools"]["names"]) ==
             Enum.sort(manifest["contracts"]["tools"])

    assert result["registrations"]["runtime"] == "function"
    assert result["registrations"]["service"] == "backplane-memory-delivery"

    assert result["registrations"]["flush"]["persistenceToolNames"] ==
             ["backplane_memory_save", "backplane_memory_correct"]

    assert result["registrations"]["flush"]["lookupToolNames"] ==
             ["backplane_memory_search", "backplane_memory_get", "backplane_memory_status"]

    assert result["warnings"] == []
  end

  test "OpenClaw missing permission and invalid context fail closed without secret diagnostics" do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";
    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const warnings = [], missing = [], hooks = {};
    let calls = 0, caught;
    globalThis.fetch = async () => { calls++; throw new Error("private-secret"); };
    const base = {
      logger: { warn: (message) => warnings.push(message) },
      registerTool() {}, registerMemoryCapability() {}, registerService() {},
    };
    plugin.register({ ...base, on: (name) => missing.push(name) });
    plugin.register({ ...base, pluginConfig: { fallback_on_error: false },
      config: { plugins: { entries: { "backplane-memory": { hooks: { allowConversationAccess: true } } } } },
      on: (name, handler) => { hooks[name] = handler; },
    });
    try { await hooks.before_prompt_build({ prompt: "private-secret", messages: [] }, {}); }
    catch (error) { caught = error.message; }
    let endCaught;
    try { await hooks.agent_end({ success: true, messages: [{ role: "user", content: "private-secret" }] }, {}); }
    catch (error) { endCaught = error.message; }
    const disabled = [];
    plugin.register({ pluginConfig: { enabled: false }, on: () => disabled.push("hook"), registerTool: () => disabled.push("tool"), registerMemoryCapability: () => disabled.push("provider"), registerService: () => disabled.push("service") });
    console.log(JSON.stringify({ missing, disabled, warnings, calls, caught, endCaught }));
    '''

    {output, 0} =
      System.cmd(node, [
        "--unhandled-rejections=strict",
        "--input-type=module",
        "-e",
        script,
        source
      ])

    result = Jason.decode!(output)
    assert result["missing"] == []
    assert result["disabled"] == []
    assert result["calls"] == 0
    assert is_binary(result["caught"])
    assert is_binary(result["endCaught"])
    assert Enum.any?(result["warnings"], &String.contains?(&1, "conversation_access_required"))
    refute output =~ "private-secret"
  end
end
