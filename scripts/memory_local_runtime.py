#!/usr/bin/env python3
"""Run one isolated synthetic Claude session with the real repository capture hooks."""

import argparse
import json
import os
import shlex
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    output = ROOT / ".devenv/memory-local-evidence" / fixture["run_id"] / ("runtime-" + str(time.time_ns()))
    output.mkdir(parents=True, mode=0o700)
    for name in ("config", "activation", "project"):
        (output / name).mkdir(mode=0o700)
    receipts = output / "hooks.jsonl"
    wrapper = output / "hook.py"
    wrapper.write_text('''import json, pathlib, subprocess, sys, time
raw = sys.stdin.buffer.read(1000001)
if len(raw) > 1000000:
    raise SystemExit(1)
data = json.loads(raw)
with pathlib.Path(sys.argv[1]).open("a") as stream:
    stream.write(json.dumps({"hook": sys.argv[2], "session_id": data.get("session_id"), "recorded_at_ns": time.time_ns()}) + "\\n")
result = subprocess.run(["bash", sys.argv[3]], input=raw, timeout=25)
raise SystemExit(result.returncode)
''')
    hooks = {}
    for event, script in (("SessionStart", "session-start.sh"), ("UserPromptSubmit", "user-prompt-submit.sh"),
                          ("Stop", "stop.sh"), ("SessionEnd", "session-end.sh")):
        command = shlex.join([sys.executable, str(wrapper), str(receipts), event,
                              str(ROOT / "apps/backplane_memory/priv/hooks" / script)])
        hooks[event] = [{"hooks": [{"type": "command", "command": command, "timeout": 30}]}]
    settings = output / "settings.json"
    settings.write_text(json.dumps({"hooks": hooks}))
    environment = dict(os.environ)
    environment.update({"CLAUDE_CONFIG_DIR": str(output / "config"), "XDG_RUNTIME_DIR": str(output / "activation"),
                        "BACKPLANE_HOST_AGENT_URL": "http://127.0.0.1:4222",
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
    environment.pop("AGENTMEMORY_SDK_CHILD", None)
    # Use the explicitly available development provider, without placing its key
    # in command arguments, settings, logs, or the report.
    if not environment.get("OPENROUTER_API_KEY"):
        raise RuntimeError("OPENROUTER_API_KEY is required for the isolated runtime probe")
    environment["ANTHROPIC_AUTH_TOKEN"] = environment["OPENROUTER_API_KEY"]
    environment["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api"
    session = str(uuid.uuid4())
    command = ["claude", "-p", "--model", "anthropic/claude-haiku-4.5", "--max-budget-usd", "0.10",
               "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--setting-sources", "", "--settings", str(settings), "--session-id", session,
               "--system-prompt", "Reply to the synthetic test in one brief sentence. Do not use tools.",
               "--output-format", "json", "--no-session-persistence",
               "MEMORY-LOCAL-" + fixture["run_id"] + ": Synthetic runtime capture test. "
               "We prefer bounded OTP workers. Confirm this preference in one sentence."]
    report = {"run_id": fixture["run_id"], "runtime": "claude", "session_id": session,
              "complete_L01_L18": False, "canonical_capture_verified": False,
              "limit": "Hook invocation receipts require correlation with canonical events; they alone do not prove ingestion."}
    with (output / "stdout.json").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
        process = subprocess.Popen(command, cwd=output / "project", env=environment,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            report["exit_code"] = process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            report["exit_code"] = process.returncode
            report["timeout"] = True
    report["hook_invocations"] = [json.loads(line) for line in receipts.read_text().splitlines()] if receipts.exists() else []
    (output / "report.json").write_text(json.dumps(report, indent=2))
    for path in output.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)
    print(output / "report.json")
    return 0 if report["exit_code"] == 0 and report["hook_invocations"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
