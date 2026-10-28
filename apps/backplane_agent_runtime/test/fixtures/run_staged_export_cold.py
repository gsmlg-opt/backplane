#!/usr/bin/env python3
"""Run under flock /tmp/backplane-ir47-beam.lock; never recursively lock.
Single-host exclusive fixture custody; each BEAM exits before the next starts.
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
    argv = ["mix", "run", "--no-start", "test/fixtures/staged_export_cold_beam.exs", mode, str(data)]
    with (evidence / (mode + ".log")).open("w") as log:
        child = subprocess.Popen(argv, cwd=app, env=env, stdout=log, stderr=subprocess.STDOUT)
        pid = child.pid
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
        os.kill(pid, 0)
    except ProcessLookupError:
        stopped = True
    else:
        stopped = False
    result = {"mode": mode, "argv": argv, "os_pid": pid, "exit": code, "timed_out": timed_out, "os_exit_verified": stopped, "log": str(evidence / (mode + ".log"))}
    results.append(result)
    (evidence / "result.json").write_text(json.dumps({"data": str(data), "processes": results}, indent=2) + "\n")
    if code == 0:
        report = json.loads((evidence / (mode + ".log")).read_text().splitlines()[-1])
        assert report[mode + "_os_pid"] == str(pid)
        result["beam_os_pid_verified"] = True
        result["report"] = report
        (evidence / "result.json").write_text(json.dumps({"data": str(data), "processes": results}, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    print((evidence / (mode + ".log")).read_text()[-6000:], flush=True)
    if code or not stopped:
        sys.exit(code or 1)
assert results[0]["os_pid"] != results[1]["os_pid"]
