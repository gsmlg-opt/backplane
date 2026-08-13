defmodule Backplane.HostAgent.Memory.IntegrationPluginContractTest do
  use ExUnit.Case, async: true

  @integrations_root Path.expand("../../../../../../integrations/memory", __DIR__)

  test "Hermes packaged provider uses exact recall/remember protocol and async capture" do
    python = System.find_executable("python3") || flunk("python3 is required")
    source = Path.join([@integrations_root, "hermes", "__init__.py"])

    script = ~S'''
    import importlib.util, json, sys, time
    from urllib.error import URLError

    spec = importlib.util.spec_from_file_location("backplane_memory_hermes", sys.argv[1])
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    calls = []

    class Response:
        def __init__(self, body): self.body = body
        def __enter__(self): return self
        def __exit__(self, *_args): return False
        def read(self): return json.dumps(self.body).encode()

    def urlopen(request, timeout):
        body = json.loads(request.data.decode())
        calls.append({"url": request.full_url, "method": request.method, "body": body, "timeout": timeout})
        if request.full_url.endswith("/recall"):
            return Response({"ok": True, "result": {"results": [{"content": "prior fact"}]}})
        return Response({"ok": True, "result": {"success": True}})

    plugin.urlopen = urlopen
    provider = plugin.BackplaneMemoryProvider()
    provider._base = "http://127.0.0.1:4222"
    provider._agent_id = "hermes-test"
    provider._session_id = "session-1"
    provider._scope = "/workspace/backplane"
    recall = provider.prefetch("memory query")
    saved = json.loads(provider.handle_tool_call("memory_save", {"content": "remember me", "tags": ["m18"]}))

    def slow_post(*_args): time.sleep(0.4)
    plugin._post = slow_post
    started = time.monotonic()
    provider.sync_turn("user", "assistant", session_id="session-2")
    elapsed_ms = (time.monotonic() - started) * 1000

    plugin.urlopen = lambda *_args, **_kwargs: (_ for _ in ()).throw(URLError("private-secret"))
    failure = plugin._post("http://127.0.0.1:4222", "hermes-test", "recall", {"query": "private-secret"})

    print(json.dumps({"calls": calls, "recall": recall, "saved": saved, "elapsed_ms": elapsed_ms, "failure": failure}))
    '''

    {output, 0} = System.cmd(python, ["-c", script, source], stderr_to_stdout: true)
    refute output =~ "private-secret"
    result = Jason.decode!(output)

    assert result["recall"] == "- prior fact"
    assert result["saved"] == %{"success" => true}
    assert result["elapsed_ms"] < 100

    assert [recall, remember] = result["calls"]
    assert recall["url"] == "http://127.0.0.1:4222/memory/hermes-test/call/recall"
    assert recall["method"] == "POST"

    assert recall["body"] == %{
             "query" => "memory query",
             "limit" => 5,
             "scope" => "/workspace/backplane"
           }

    assert remember["url"] == "http://127.0.0.1:4222/memory/hermes-test/call/remember"

    assert remember["body"] == %{
             "content" => "remember me",
             "type" => "semantic",
             "scope" => "/workspace/backplane",
             "tags" => ["m18"],
             "session_id" => "session-1"
           }
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
