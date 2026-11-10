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

  test "OpenClaw packaged plugin registers the global memory tools, hooks and instructions" do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";
    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const hooks = {}, registrations = {}, warnings = [];
    plugin.register({
      pluginConfig: { enabled: true },
      config: { plugins: { entries: { "backplane-memory": { hooks: { allowConversationAccess: true } } } } },
      logger: { warn: (message) => warnings.push(message) },
      on: (name, _handler, options) => { hooks[name] = options || {}; },
      registerTool: (factory, options) => { registrations.tools = { contextVersion: factory.contextVersion, names: options.names }; },
      registerMemoryCapability: (capability) => {
        registrations.flush = capability.providerFlushPlanResolver();
        registrations.runtime = typeof capability.providerRuntime.open;
        registrations.prompt = capability.promptBuilder();
      },
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

    assert result["registrations"]["tools"]["contextVersion"] == 2

    manifest =
      @integrations_root
      |> Path.join("openclaw/openclaw.plugin.json")
      |> File.read!()
      |> Jason.decode!()

    tool_names =
      Enum.map(Backplane.MemoryToolContract.tools(), fn "memory::" <> short ->
        "backplane_memory_" <> short
      end)

    assert Enum.sort(result["registrations"]["tools"]["names"]) == Enum.sort(tool_names)
    assert Enum.sort(manifest["contracts"]["tools"]) == Enum.sort(tool_names)
    refute Map.has_key?(manifest["configSchema"]["properties"], "bindings")

    assert hd(result["registrations"]["prompt"]) ==
             File.read!(Path.join(@integrations_root, "shared/INSTRUCTIONS.md"))

    assert String.trim_trailing(hd(result["registrations"]["prompt"])) ==
             Backplane.MemoryToolContract.instructions()

    assert result["registrations"]["runtime"] == "function"
    assert result["registrations"]["service"] == "backplane-memory-delivery"

    assert result["registrations"]["flush"]["persistenceToolNames"] == [
             "backplane_memory_remember"
           ]

    assert result["registrations"]["flush"]["lookupToolNames"] ==
             ["backplane_memory_search", "backplane_memory_get", "backplane_memory_recent"]

    assert result["warnings"] == []
  end

  @tag :tmp_dir
  test "OpenClaw hooks degrade without throwing or leaking content and capture stays contract-valid",
       %{tmp_dir: tmp_dir} do
    node = System.find_executable("node") || flunk("node is required")
    source = Path.join([@integrations_root, "openclaw", "plugin.mjs"])

    script = ~S'''
    import { pathToFileURL } from "node:url";
    const { default: plugin } = await import(pathToFileURL(process.argv[1]).href);
    const warnings = [], missing = [], hooks = {}, captures = [], paths = [];
    let mode = "throw";
    globalThis.fetch = async (url, init) => {
      const path = new URL(url).pathname, body = JSON.parse(init.body);
      paths.push(path);
      if (mode === "throw" && path.startsWith("/memory/")) throw new Error("private-secret");
      if (path.startsWith("/memory/")) return { ok: false, status: 503, json: async () => ({ ok: false, error: "gateway_unavailable" }) };
      if (path.startsWith("/capture/v1/hooks/")) {
        captures.push({ hook: path.split("/").at(-1), body });
        return { ok: true, status: 202, json: async () => ({ ok: true, status: "accepted", event_id: body.event_id }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { protocol: "openclaw_capture.v1", items: [] } }) };
    };
    const base = {
      logger: { warn: (message) => warnings.push(message) },
      registerTool() {}, registerMemoryCapability() {}, registerService() {},
    };
    plugin.register({ ...base, on: (name) => missing.push(name) });
    let dispose;
    plugin.register({ ...base, pluginConfig: { journal_path: process.argv[2] + "/delivery.sqlite" },
      config: { plugins: { entries: { "backplane-memory": { hooks: { allowConversationAccess: true } } } } },
      on: (name, handler) => { hooks[name] = handler; }, lifecycle: { onDispose: (fn) => { dispose = fn; } },
    });
    const results = {};
    results.invalid = await hooks.before_prompt_build({ prompt: "private-secret", messages: [] }, {}) ?? null;
    const ctx = { agentId: "main", sessionId: "session-one", sessionKey: "agent:main:main", runId: "run-one" };
    results.thrown = await hooks.before_prompt_build({ prompt: "private-secret", messages: [] }, ctx) ?? null;
    mode = "unavailable";
    const next = { ...ctx, runId: "run-two" };
    const history = [{ role: "user", content: "private-secret" }];
    results.unavailable = await hooks.before_prompt_build({ prompt: "what changed?", messages: history }, next) ?? null;
    await hooks.agent_end({ messages: [...history, { role: "user", content: "what changed?" }, { role: "assistant", content: "an answer" }] }, next);
    await hooks.session_end({ sessionId: "session-one", reason: "reset" }, ctx);
    await new Promise((resolve) => setTimeout(resolve, 100));
    await dispose();
    console.log(JSON.stringify({ missing, warnings, results, captures, paths }));
    '''

    {output, 0} =
      System.cmd(node, [
        "--unhandled-rejections=strict",
        "--input-type=module",
        "-e",
        script,
        source,
        tmp_dir
      ])

    result = Jason.decode!(output)
    assert result["missing"] == []
    assert result["results"] == %{"invalid" => nil, "thrown" => nil, "unavailable" => nil}
    assert Enum.any?(result["warnings"], &String.contains?(&1, "conversation_access_required"))

    assert Enum.any?(
             result["warnings"],
             &String.contains?(&1, "memory search failed: gateway_unavailable (HTTP 503)")
           )

    refute Enum.any?(result["warnings"], &String.contains?(&1, "private-secret"))
    refute Enum.any?(result["paths"], &(&1 =~ ~r/source_|recall|\/list$/))

    assert Enum.map(result["captures"], & &1["hook"]) ==
             ["session-start", "message", "message", "message", "session-end"]

    for %{"hook" => hook, "body" => body} <- result["captures"] do
      assert {:ok, _event_type} = Backplane.OpenClawCaptureContract.validate(hook, body)
    end
  end
end
