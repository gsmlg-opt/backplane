#!/usr/bin/env python3
"""Own a local Memory dev stack; never adopt existing processes or database state."""

import argparse
import contextlib
import ctypes
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OWNER = "backplane-memory-local-dev-v1"
CHILDREN = {}


def build_commands(config):
    return {"gateway": ["devenv", "up"],
            "host": ["devenv", "shell", "--", "sh", "-c",
                     "cd apps/backplane_host_agent && exec mix agent.run"]}


def endpoints(host_port=4222):
    return {
        "public": "http://127.0.0.1:4220/",
        "admin": "http://127.0.0.1:4221/",
        "host": f"http://127.0.0.1:{host_port}/",
    }


def process_identity(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart=", "-o", "pgid=", "-o", "uid=", "-o", "stat=", "-o", "ppid="],
        capture_output=True, text=True, check=False,
    )
    parts = result.stdout.split()
    if result.returncode or len(parts) != 9 or "Z" in parts[7]:
        return None
    started_at = " ".join(parts[:5])
    proc_stat = Path(f"/proc/{pid}/stat")
    if proc_stat.exists():
        try:
            birth = "proc:" + proc_stat.read_text().rpartition(")")[2].split()[19]
        except (OSError, IndexError):
            return None
    elif sys.platform == "darwin":
        # Darwin proc_bsdinfo includes the kernel creation time in microseconds.
        # lstart alone has second resolution and cannot reliably detect PID reuse.
        info = ctypes.create_string_buffer(136)
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        query = libproc.proc_pidinfo
        query.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        query.restype = ctypes.c_int
        if query(pid, 3, 0, info, len(info)) != len(info):
            return None
        seconds, micros = struct.unpack_from("=QQ", info.raw, 120)
        birth = f"darwin:{seconds}:{micros}"
    else:
        raise RuntimeError("OS process creation identity requires Linux /proc or Darwin libproc")
    return {"started_at": started_at, "birth": birth, "pgid": int(parts[5]),
            "uid": int(parts[6]), "ppid": int(parts[8])}


@contextlib.contextmanager
def operation(state_dir):
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state_dir.stat().st_uid != os.getuid():
        raise RuntimeError(f"unowned state directory: {state_dir}")
    lock = state_dir / "operation.lock"
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError(f"another operation or stale lock exists: {lock}") from None
    try:
        yield
    finally:
        os.close(fd)
        lock.unlink()


def write_state(state_dir, state):
    temporary = state_dir / "state.json.tmp"
    with temporary.open("w") as stream:
        os.chmod(temporary, 0o600)
        json.dump(state, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(state_dir / "state.json")


def read_state(state_dir):
    path = state_dir / "state.json"
    try:
        state = json.loads(path.read_text())
        valid = (
            path.stat().st_uid == os.getuid()
            and state["owner"] == OWNER
            and state["root"] == str(ROOT)
            and state["uid"] == os.getuid()
            and isinstance(state["processes"], list)
        )
    except (OSError, ValueError, KeyError, TypeError):
        valid = False
    if not valid:
        raise RuntimeError(f"invalid or unowned state: {path}")
    return state


def owns(record):
    return record["pid"] == record["pgid"] and same_process(record)


def same_process(record):
    return same_identity(record, process_identity(record["pid"]))


def same_identity(record, current):
    return (
        record["uid"] == os.getuid()
        and current is not None
        and all(current[key] == record[key] for key in ("birth", "pgid", "uid"))
    )


def remember_descendants(record):
    """Capture ancestry only while a birth-fenced parent is still alive."""
    known = [record, *record.get("descendants", [])]
    for process in known:
        current = process_identity(process["pid"])
        if current is not None and not same_identity(process, current):
            raise RuntimeError(f"stale process or ownership mismatch for {record['name']}; state retained")
    result = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, check=True)
    parents = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if len(line.split()) == 2]
    seen = {process["pid"] for process in known}
    for parent in known:
        if not same_process(parent):
            continue
        for pid, ppid in parents:
            if ppid != parent["pid"] or pid in seen:
                continue
            identity = process_identity(pid)
            if identity is not None and identity["ppid"] == ppid and same_process(parent):
                if identity["uid"] != os.getuid():
                    raise RuntimeError("descendant ownership changed; state retained")
                descendant = {"pid": pid, **identity}
                record.setdefault("descendants", []).append(descendant)
                known.append(descendant)
                seen.add(pid)


def capture_state(state_dir, state):
    for record in state["processes"]:
        remember_descendants(record)
    write_state(state_dir, state)


def group_alive(pgid):
    result = subprocess.run(["ps", "-axo", "pgid=,stat="], capture_output=True, text=True, check=True)
    return any(
        len(parts) == 2 and parts[0] == str(pgid) and "Z" not in parts[1]
        for parts in (line.split() for line in result.stdout.splitlines())
    )


def group_members(pgid):
    result = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="],
                            capture_output=True, text=True, check=True)
    return [int(parts[0]) for parts in (line.split() for line in result.stdout.splitlines())
            if len(parts) == 3 and parts[1] == str(pgid) and "Z" not in parts[2]]


def signal_owned_group(pgid, processes, sig=None):
    members = group_members(pgid)
    known = {process["pid"]: process for process in processes}
    live = False
    for pid in members:
        if pid not in known:
            raise RuntimeError("process group ownership changed; state retained; refusing signal")
        current = process_identity(pid)
        # Shutdown may reap a member after the snapshot. An unavailable identity
        # is safe to skip only if a fresh snapshot confirms it is no longer live.
        if current is None and pid not in group_members(pgid):
            continue
        if (current is None or known[pid]["uid"] != os.getuid()
                or any(current[key] != known[pid][key] for key in ("birth", "pgid", "uid"))):
            raise RuntimeError("process group ownership changed; state retained; refusing signal")
        live = True
    if live and sig is not None:
        # The final validated member may exit before the kernel receives this.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, sig)


def stop_records(records, grace=5, allow_gone=False, persist=None):
    active = []
    # Validate every record before sending the first signal.
    for record in records:
        remember_descendants(record)
        descendants = record.get("descendants", [])
        root_gone = process_identity(record["pid"]) is None
        if record["pid"] != record["pgid"] or (not root_gone and not owns(record)):
            raise RuntimeError(f"stale process or ownership mismatch for {record['name']}; state retained")
        if root_gone and not descendants and not allow_gone:
            raise RuntimeError(f"stale process or ownership mismatch for {record['name']}; state retained")
        active.extend([record, *descendants])
    if persist is not None:
        persist()
    groups = list(dict.fromkeys(process["pgid"] for process in active))
    for pgid in groups:
        signal_owned_group(pgid, active)
    for pgid in reversed(groups):
        signal_owned_group(pgid, active, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while any(group_alive(pgid) for pgid in groups) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pgid in reversed(groups):
        signal_owned_group(pgid, active, signal.SIGKILL)
    deadline = time.monotonic() + 2
    while any(group_alive(pgid) for pgid in groups) and time.monotonic() < deadline:
        time.sleep(0.1)
    if any(group_alive(pgid) for pgid in groups):
        raise RuntimeError("owned processes did not stop; state retained")
    for record in records:
        child = CHILDREN.pop(record["pid"], None)
        if child is not None:
            child.wait(timeout=2)


def http_ready(url):
    try:
        with urllib.request.urlopen(url, timeout=0.5) as reply:
            return reply.status < 500
    except urllib.error.HTTPError as error:
        return error.code < 500
    except (OSError, urllib.error.URLError):
        return False


def check_ports(urls):
    for url in set(urls.values()):
        port = urllib.parse.urlparse(url).port
        for address in ("127.0.0.1", "::1"):
            try:
                with socket.create_connection((address, port), timeout=0.2):
                    raise RuntimeError(f"port {port} is occupied; refusing to adopt an existing service")
            except OSError:
                pass


def start(state_dir, config, host_port=4222, timeout=120, host_first=False, host_only=False):
    if host_only and host_first:
        raise RuntimeError("--host-only and --host-first cannot be combined")
    state_dir, config = Path(state_dir).resolve(), Path(config).resolve()
    with operation(state_dir):
        if (state_dir / "state.json").exists():
            raise RuntimeError(f"stack state already exists: {state_dir / 'state.json'}; inspect status first")
        if not config.is_file():
            raise RuntimeError(f"host config must exist: {config}")
        if not 0 < host_port < 65536 or timeout <= 0:
            raise RuntimeError("host port and readiness timeout must be positive and valid")
        urls = endpoints(host_port)
        if host_only:
            urls = {"host": urls["host"]}
        check_ports(urls)
        run_id = uuid.uuid4().hex
        logs = state_dir / run_id
        logs.mkdir(mode=0o700)
        state = {"owner": OWNER, "root": str(ROOT), "uid": os.getuid(), "run_id": run_id,
                 "host_port": host_port, "config": str(config), "urls": urls, "processes": []}
        write_state(state_dir, state)
        commands = build_commands(config)
        deadline = time.monotonic() + timeout
        try:
            for name in (["host"] if host_only else (["host", "gateway"] if host_first else ["gateway", "host"])):
                log = logs / f"{name}.log"
                env = os.environ.copy()
                if name == "host":
                    env["BACKPLANE_HOST_AGENT_CONFIG"] = str(config)
                with log.open("ab") as output:
                    os.chmod(log, 0o600)
                    child = subprocess.Popen(commands[name], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                             stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                CHILDREN[child.pid] = child
                identity = process_identity(child.pid)
                if identity is None:
                    child.wait(timeout=2)
                    raise RuntimeError(f"{name} exited during startup; inspect log {log}")
                record = {"name": name, "pid": child.pid, "log": str(log), **identity}
                state["processes"].append(record)
                capture_state(state_dir, state)
                required = [urls["host"]] if name == "host" else [urls["public"], urls["admin"]]
                while not all(http_ready(url) for url in required):
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"{name} readiness failed; inspect log {log} and state {state_dir}")
                    capture_state(state_dir, state)
                    time.sleep(0.1)
            capture_state(state_dir, state)
            for record in state["processes"]:
                if not owns(record):
                    raise RuntimeError(f"{record['name']} exited during stack startup; inspect log {record['log']}")
            if not all(http_ready(url) for url in urls.values()):
                raise RuntimeError("a service lost HTTP readiness during stack startup; inspect recorded logs")
            return state
        except BaseException:
            stop_records(state["processes"], allow_gone=True,
                         persist=lambda: write_state(state_dir, state))
            (state_dir / "state.json").unlink()
            raise


def status(state_dir):
    state_dir = Path(state_dir).resolve()
    if not (state_dir / "state.json").exists():
        return {"state": "not_started", "processes": [], "http_ready": {}}
    state = read_state(state_dir)
    return {"state": "recorded", "run_id": state["run_id"], "state_dir": str(state_dir),
            "processes": [{**record, "running": owns(record)} for record in state["processes"]],
            "http_ready": {name: http_ready(url) for name, url in state["urls"].items()}, "urls": state["urls"]}


def stop(state_dir):
    state_dir = Path(state_dir).resolve()
    with operation(state_dir):
        state = read_state(state_dir)
        for record in state["processes"]:
            if record.get("stopped") and group_alive(record["pgid"]):
                raise RuntimeError("an intentionally stopped process group is occupied; state retained")
        stop_records([record for record in state["processes"] if not record.get("stopped")],
                     persist=lambda: write_state(state_dir, state))
        (state_dir / "state.json").unlink()
    return {"state": "stopped", "logs": str(state_dir / state["run_id"])}


def service(state_dir, name, action, timeout=120):
    """Inject an owned service outage or restart it without stopping its peer."""
    if name not in ("gateway", "host") or action not in ("start", "stop", "restart") or timeout <= 0:
        raise RuntimeError("invalid service operation")
    state_dir = Path(state_dir).resolve()
    with operation(state_dir):
        state = read_state(state_dir)
        record = next((item for item in state["processes"] if item["name"] == name), None)
        if record is None or not state.get("config"):
            raise RuntimeError("stack record cannot safely restart this service")
        if action in ("stop", "restart"):
            stop_records([record], allow_gone=True, persist=lambda: write_state(state_dir, state))
            record["stopped"] = True
            capture_state(state_dir, state)
        if action in ("start", "restart"):
            if not record.get("stopped") or group_alive(record["pgid"]):
                raise RuntimeError("service is not stopped; inspect its recorded ownership")
            urls = {key: value for key, value in state["urls"].items()
                    if (key == "host") == (name == "host")}
            check_ports(urls)
            config = Path(state["config"])
            if not config.is_file():
                raise RuntimeError("recorded host configuration is missing")
            log = state_dir / state["run_id"] / f"{name}-{time.time_ns()}.log"
            env = os.environ.copy()
            if name == "host":
                env["BACKPLANE_HOST_AGENT_CONFIG"] = str(config)
            with log.open("ab") as output:
                os.chmod(log, 0o600)
                child = subprocess.Popen(build_commands(config)[name], cwd=ROOT, env=env,
                                         stdin=subprocess.DEVNULL, stdout=output,
                                         stderr=subprocess.STDOUT, start_new_session=True)
            CHILDREN[child.pid] = child
            identity = process_identity(child.pid)
            if identity is None:
                child.wait(timeout=2)
                CHILDREN.pop(child.pid, None)
                raise RuntimeError(f"{name} exited during startup; inspect log {log}")
            replacement = {"name": name, "pid": child.pid, "log": str(log), **identity}
            state["processes"][state["processes"].index(record)] = replacement
            write_state(state_dir, state)
            deadline = time.monotonic() + timeout
            while not all(http_ready(url) for url in urls.values()):
                if child.poll() is not None or time.monotonic() >= deadline:
                    stop_records([replacement], allow_gone=True,
                                 persist=lambda: write_state(state_dir, state))
                    replacement["stopped"] = True
                    write_state(state_dir, state)
                    raise RuntimeError(f"{name} readiness failed; inspect log {log}")
                capture_state(state_dir, state)
                time.sleep(0.1)
            capture_state(state_dir, state)
    return status(state_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("start")
    launch.add_argument("--config", required=True, type=Path)
    launch.add_argument("--host-port", type=int, default=4222, help="must match YAML http_port")
    launch.add_argument("--timeout", type=float, default=120)
    launch.add_argument("--host-first", action="store_true")
    launch.add_argument("--host-only", action="store_true", help="own only this host beside an existing gateway")
    commands.add_parser("status")
    commands.add_parser("stop")
    individual = commands.add_parser("service", help="stop/start/restart one owned service for recovery checks")
    individual.add_argument("name", choices=["gateway", "host"])
    individual.add_argument("action", choices=["start", "stop", "restart"])
    individual.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    try:
        if args.command == "start":
            result = start(args.state_dir, args.config, args.host_port, args.timeout, args.host_first, args.host_only)
        elif args.command == "service":
            result = service(args.state_dir, args.name, args.action, args.timeout)
        else:
            result = globals()[args.command](args.state_dir)
        print(json.dumps(result, indent=2))
        return 0
    except (RuntimeError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
