#!/usr/bin/env python3
"""Run under the parent's exclusive BEAM lock; producer exits before consumer.

The file host has single-writer local custody. This demonstrates independent
process reload, not concurrent-writer or power-loss durability.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

app = Path(__file__).resolve().parents[2]
evidence = Path(sys.argv[1]).resolve()
evidence.mkdir(parents=True, exist_ok=True)
data = evidence / ("host-" + str(time.time_ns()))
env = os.environ.copy()
env["MIX_ENV"] = "test"
env["ERL_FLAGS"] = "+S 4:4"
results = []
for mode in ("producer", "consumer"):
    argv = ["mix", "run", "--no-start", "test/fixtures/headless_cold_beam.exs", mode, str(data)]
    log_path = evidence / (mode + ".log")
    with log_path.open("w") as log:
        child = subprocess.Popen(argv, cwd=app, env=env, stdout=log, stderr=subprocess.STDOUT)
        timed_out = False
        try:
            code = child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            timed_out = True
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            code = 124
    try:
        os.kill(child.pid, 0)
    except ProcessLookupError:
        stopped = True
    else:
        stopped = False
    result = {"mode": mode, "argv": argv, "os_pid": child.pid, "exit": code,
              "timed_out": timed_out, "os_exit_verified": stopped, "log": str(log_path)}
    results.append(result)
    if code == 0:
        report = json.loads(log_path.read_text().splitlines()[-1])
        assert report[mode + "_os_pid"] == str(child.pid)
        result.update(beam_os_pid_verified=True, report=report)
    (evidence / "result.json").write_text(json.dumps({"data": str(data), "processes": results}, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    print(log_path.read_text()[-6000:], flush=True)
    if code or not stopped:
        sys.exit(code or 1)
assert results[0]["os_pid"] != results[1]["os_pid"]
