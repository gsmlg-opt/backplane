"""Exercise tools-only Hermes over real host HTTP, without canonical settlement.

Native capture and canonical smoke remain the standalone Hermes smoke's job.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time


def load_provider(path):
    name = "backplane_hermes_provisional_http"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module.BackplaneMemoryProvider()


def completed_prefetch(provider, query, session):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        assert provider.prefetch(query, session_id=session) == ""
        # Observe completion only; the actual worker must populate this cache.
        # Peer discovery may invalidate a generation while the request runs.
        with provider._state_lock:
            key = (session, query, provider._generation)
            cached = provider._cache.get(key)
            if cached is not None:
                assert cached[1] == "", "unsupported provisional context was injected"
                return
        time.sleep(0.01)
    raise AssertionError("asynchronous HTTP prefetch did not complete")


def run(args):
    provider = load_provider(args.provider)
    home = Path(args.home)
    provider.save_config({"url": args.base_url, "agent_id": "hermes"}, home)
    session = "hermes-provisional-http"
    cwd = str(home / "workspace")
    provider.initialize(session, hermes_home=str(home), agent_context="subagent", cwd=cwd)
    content = "Hermes provisional HTTP fixture aurora"
    prompt = provider.system_prompt_block()

    def tool(name, values):
        result = json.loads(provider.handle_tool_call(name, values))
        assert isinstance(result, dict) and result.get("success") is not False
        assert not result.get("error"), result
        return result

    def read(name, values):
        result = tool(name, values)
        assert isinstance(result.get("results"), list)
        assert isinstance(result.get("provisional_results", []), list)
        assert result["mode"] == args.mode
        if args.mode == "online":
            assert result["authority"] == "canonical_with_provisional"
            assert result["consistency"] == "read_your_writes"
            assert result["stale"] is False
            if name == "memory_list":
                assert result["results"] == [], "pending row became canonical"
                rows = result["provisional_results"]
            else:
                # MemoryFacade intentionally merges recall overlays into results;
                # each row must still carry truthful provisional authority.
                rows = result["results"]
        else:
            assert result["authority"] == "provisional"
            assert result["consistency"] == "provisional_only"
            assert result["stale"] is True
            rows = result["results"]
        return rows

    try:
        assert provider.is_available()
        saved = tool("memory_save", {"content": content, "tags": ["aurora"]})
        assert saved["id"] and saved["scope"] == "host-bound"
        assert saved["sync_state"] == "pending" and saved["dedup"] is False
        assert saved["authority"] == "provisional"
        assert saved["consistency"] == "pending_canonical_ack"
        assert not saved.get("canonical_id")

        for name, values in (("memory_list", {}), ("memory_recall", {"query": "aurora"})):
            rows = read(name, values)
            assert len(rows) == 1 and rows[0]["id"] == saved["id"]
            assert rows[0]["content"] == content
            assert rows[0]["scope"] == "host-bound" and rows[0]["agent_id"] == "hermes"
            # The HTTP provisional projection omits session_id; the Elixir
            # fixture verifies its exact value in the durable memory row.
            assert rows[0]["provisional"] is True and rows[0]["authority"] == "provisional"
            assert not rows[0].get("canonical_id")

        completed_prefetch(provider, "aurora", session)
        assert provider.system_prompt_block() == prompt and content not in prompt
        rejected = json.loads(provider.handle_tool_call("memory_list", {"scope": cwd}))
        assert rejected.get("success") is False and rejected.get("http_status") == 400
        assert rejected.get("error") in {"invalid_scope", "unknown_scope", "invalid_arguments", "invalid_request"}
        forgotten = tool("memory_forget", {"id": saved["id"]})
        assert forgotten["id"] == saved["id"] and forgotten["sync_state"] == "pending"
        assert forgotten["authority"] == "provisional"
        assert forgotten["consistency"] == "pending_canonical_ack"
        assert read("memory_list", {}) == []
        assert read("memory_recall", {"query": "aurora"}) == []
        completed_prefetch(provider, "aurora", session)
        assert provider.system_prompt_block() == prompt
    finally:
        provider.shutdown()
        assert provider.delivery_status()["worker_alive"] is False

    return {"id": saved["id"], "session_id": session, "mode": args.mode, "worker_stopped": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--mode", required=True, choices=("online", "offline"))
    print(json.dumps(run(parser.parse_args())))
