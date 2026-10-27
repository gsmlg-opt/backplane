#!/usr/bin/env python3
"""Sequential independent BEAM custody; not production multi-writer durability."""
import json
import os
import pathlib
import subprocess
import sys
import time

app = pathlib.Path(__file__).resolve().parents[2]
root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
data = root / ("cold-" + str(time.time_ns()))
env = os.environ.copy()
env.update(MIX_ENV="test", ERL_FLAGS="+S 4:4")
results = []
for mode in ("producer", "consumer"):
    command = ["mix", "run", "--no-start", "test/fixtures/goal_settlement_cold_beam.exs", mode, str(data)]
    log = root / (mode + ".log")
    with log.open("w") as output:
        child = subprocess.Popen(command, cwd=app, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=45)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            code = 124
    try:
        os.kill(child.pid, 0)
        stopped = False
    except ProcessLookupError:
        stopped = True
    result = {"mode": mode, "os_pid": child.pid, "exit": code, "os_exit_verified": stopped, "log": str(log)}
    if code == 0:
        report = json.loads(log.read_text().splitlines()[-1])
        assert report[mode + "_os_pid"] == str(child.pid)
        result["report"] = report
    results.append(result)
    (root / "cold-result.json").write_text(json.dumps({"data": str(data), "processes": results}, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    if code or not stopped:
        print(log.read_text()[-10000:], flush=True)
        sys.exit(code or 1)
assert results[0]["os_pid"] != results[1]["os_pid"]
