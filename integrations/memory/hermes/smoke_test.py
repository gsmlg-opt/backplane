"""Exercise the packaged Hermes provider against a running host Memory API.

Uses one unique tagged record, verifies readback/recall/prompt injection, and
deletes it. This checks the actual plugin, not just endpoint connectivity.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import uuid


def contains_record(result, content):
    # Online list keeps pending rows in a sideband, outside canonical pagination.
    assert isinstance(result, dict) and result.get("success") is not False and not result.get("error"), "memory read failed"
    assert isinstance(result.get("results"), list), "invalid memory results"
    assert isinstance(result.get("provisional_results", []), list), "invalid provisional results"
    return any(row["content"] == content
               for group in ("results", "provisional_results")
               for row in result.get(group, []))


def validate_scope_rejection(result):
    assert (isinstance(result, dict) and result.get("success") is False
            and result.get("http_status") == 400
            and result.get("error") in {"invalid_scope", "unknown_scope", "invalid_arguments", "invalid_request"}), "scope override was not rejected by authorization"


def run(base_url, agent_id, cwd):
    os.environ["BACKPLANE_MEMORY_URL"] = base_url
    os.environ["BACKPLANE_MEMORY_AGENT_ID"] = agent_id
    spec = importlib.util.spec_from_file_location(
        "backplane_memory_smoke", Path(__file__).with_name("__init__.py")
    )
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    provider = plugin.BackplaneMemoryProvider()
    provider.initialize("plugin-smoke", cwd=cwd)
    assert provider.is_available(), "provider unavailable"
    marker = "bppluginsmoke" + uuid.uuid4().hex
    content = "Backplane plugin smoke " + marker
    saved_id = None
    try:
        saved = json.loads(provider.handle_tool_call(
            "memory_save", {"content": content, "tags": [marker]}
        ))
        assert saved.get("id"), f"save failed: {saved}"
        saved_id = saved["id"]
        listed = json.loads(provider.handle_tool_call("memory_list", {"tag": marker}))
        assert contains_record(listed, content), "readback missing"
        recalled = json.loads(provider.handle_tool_call("memory_recall", {"query": marker}))
        assert contains_record(recalled, content), "recall missing"
        assert content in provider.prefetch(marker), "prefetch missing"
        assert content in provider.system_prompt_block(), "prompt injection missing"
        rejected = json.loads(provider.handle_tool_call("memory_list", {"scope": cwd}))
        validate_scope_rejection(rejected)
    finally:
        if saved_id:
            forgotten = json.loads(provider.handle_tool_call("memory_forget", {"id": saved_id}))
            assert forgotten.get("success") is not False and not forgotten.get("error"), "forget failed"
    listed = json.loads(provider.handle_tool_call("memory_list", {"tag": marker}))
    assert not contains_record(listed, content), "deleted record still listed"
    recalled = json.loads(provider.handle_tool_call("memory_recall", {"query": marker}))
    assert not contains_record(recalled, content), "deleted record recalled"
    return {"write": True, "readback": True, "recall": True, "prompt": True,
            "scope_rejected": True, "delete": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:4222")
    parser.add_argument("--agent-id", default="hermes")
    parser.add_argument("--cwd", default="/Users/gao/.dotfiles")
    args = parser.parse_args()
    print(json.dumps(run(args.base_url, args.agent_id, args.cwd)))
