# Memory Hook Activation Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Claude Code hook ingestion working across resume, clear, and compact lifecycles by mapping each effective activation to one immutable Backplane Memory session.

**Architecture:** Add one adjacent Python helper that owns private per-user activation state, locking, CAS cleanup, and the existing non-blocking curl call. The ten installed shell entrypoints remain the only configured commands, parse hook JSON once, resolve the activation before constructing bodies and idempotency keys, and keep the backend session/event invariants unchanged.

**Tech Stack:** Bash, Python 3 standard library (`fcntl`, `hashlib`, `json`, `os`, `pathlib`, `stat`, `subprocess`, `tempfile`, `uuid`), Elixir/ExUnit, Mix releases.

---

## File structure

**Create:**

- `apps/backplane_memory/priv/hooks/activation_session.py` — validates Claude IDs, owns private state and file locking, establishes/resolves activation IDs, performs compare-and-delete cleanup, and invokes curl without a shell.

**Modify:**

- `apps/backplane_memory/priv/hooks/session-start.sh` — require a supported `source`, establish the activation, build the start body with the resolved ID, and post it.
- `apps/backplane_memory/priv/hooks/session-end.sh` — capture the resolved activation, post the end body, and CAS-delete that mapping in `finally`.
- `apps/backplane_memory/priv/hooks/user-prompt-submit.sh` — resolve before building the user-message body.
- `apps/backplane_memory/priv/hooks/post-tool-use.sh` — resolve before building the completed-tool body and idempotency key.
- `apps/backplane_memory/priv/hooks/post-tool-use-failure.sh` — resolve before building the failed-tool body and idempotency key.
- `apps/backplane_memory/priv/hooks/pre-compact.sh` — resolve before building the compact observation.
- `apps/backplane_memory/priv/hooks/subagent-start.sh` — resolve before building the child-start body and idempotency key.
- `apps/backplane_memory/priv/hooks/subagent-stop.sh` — resolve before building the child-end body and idempotency key.
- `apps/backplane_memory/priv/hooks/stop.sh` — resolve before building the completed-run body.
- `apps/backplane_memory/priv/hooks/post-commit.sh` — retain the shell-aware commit detector, then resolve before building the commit body and idempotency key.
- `apps/backplane_memory/test/hooks/hook_scripts_test.exs` — isolate runtime state, preserve curl/Python instrumentation, and cover helper security plus complete lifecycle behavior.
- `apps/backplane_memory/test/mix/tasks/memory_connect_test.exs` — prove the helper is packaged adjacent to installed handlers without becoming a handler.

No Elixir backend module, schema, migration, HTTP route, event taxonomy, or release overlay changes.

### Task 1: Finish the shell-aware post-commit detector correction

**Files:**

- Modify: `apps/backplane_memory/priv/hooks/post-commit.sh`
- Test: `apps/backplane_memory/test/hooks/hook_scripts_test.exs`

The worktree already contains the test-first correction raised by Task 1.8 quality review. Its recorded RED run was 16 tests with two failures: quoted/heredoc text was misclassified and environment/config-prefixed Git commands were missed.

- [ ] **Step 1: Verify the regression cases remain explicit**

Keep these negative and positive commands in the focused tests:

```elixir
negative = [
  "git status",
  "echo git commit",
  "git commitment --help",
  ~s(printf "%s\\n" "nothing; git commit -m fake"),
  "cat <<'EOF'\ngit commit -m fake\nEOF"
]

positive = [
  "FOO=bar git commit -m env",
  "env FOO=bar git commit -m env-command",
  "git -c user.name=agent commit -m config",
  "cd /tmp && git -C /work -c user.name=agent commit -m chained"
]
```

- [ ] **Step 2: Run the focused tests and syntax check**

Run:

```bash
devenv shell -- mix test apps/backplane_memory/test/hooks/hook_scripts_test.exs
bash -n apps/backplane_memory/priv/hooks/post-commit.sh
```

Expected: 16 tests, 0 failures; `bash -n` exits 0.

- [ ] **Step 3: Commit only the detector correction**

```bash
git add apps/backplane_memory/priv/hooks/post-commit.sh \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs
git diff --cached --check
git commit -m "fix(memory): detect post-commit hooks structurally"
```

### Task 2: Add private activation-state primitives

**Files:**

- Create: `apps/backplane_memory/priv/hooks/activation_session.py`
- Test: `apps/backplane_memory/test/hooks/hook_scripts_test.exs`

- [ ] **Step 1: Add failing helper-contract tests**

Add an ExUnit helper that invokes real Python with the hooks directory on `sys.path`, a test-owned `XDG_RUNTIME_DIR`, and a JSON action list. Drive these public Python functions directly:

```python
establish(claude_session_id, source)
resolve(claude_session_id)
prepare_end(claude_session_id)
cleanup(claude_digest, memory_session_id)
```

Assert all of the following in separate tests:

```elixir
assert startup_id == claude_id
assert clear_id == new_claude_id
assert compact_id == startup_id
assert resume_id =~ ~r/^claude-run-[0-9a-f]{12}-[0-9a-f-]{36}$/
refute resume_id == claude_id
assert resolve_after_resume == resume_id
assert resolve_without_state == nil
assert compact_without_state == nil
assert cleanup_old_mapping_does_not_delete_new_mapping
assert two_claude_ids_resolve_independently
```

After startup, inspect the state root and assert:

```elixir
assert Bitwise.band(state_dir_stat.mode, 0o777) == 0o700
assert Bitwise.band(record_stat.mode, 0o777) == 0o600
assert Path.basename(record_path) == sha256_hex(claude_id) <> ".json"
refute File.read!(record_path) =~ claude_id
refute File.read!(record_path) =~ "prompt"
```

Also assert malformed JSON, a mismatched digest, a record larger than the helper bound, an ID containing a null byte, an oversized ID, and an `XDG_RUNTIME_DIR` that is a regular file return no resolved ID without raising.

- [ ] **Step 2: Run the helper tests to verify RED**

Run:

```bash
devenv shell -- mix test apps/backplane_memory/test/hooks/hook_scripts_test.exs
```

Expected: failures report that `activation_session` cannot be imported or its functions are missing.

- [ ] **Step 3: Implement the minimal state helper**

Add this complete helper implementation, reducing it only if the RED tests prove a branch is unnecessary:

```python
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import uuid

STATE_VERSION = 1
MAX_SESSION_ID_BYTES = 512
MAX_STATE_BYTES = 2048
STATE_DIR_NAME = "backplane-memory-hooks"
VALID_SOURCES = {"startup", "resume", "clear", "compact"}
STATE_ERRORS = (OSError, ValueError, TypeError, UnicodeError)


def _valid_id(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return len(encoded) <= MAX_SESSION_ID_BYTES


def _digest(claude_session_id):
    return hashlib.sha256(claude_session_id.encode("utf-8")).hexdigest()


def _state_root():
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
    if xdg_runtime:
        base = Path(xdg_runtime)
        name = STATE_DIR_NAME
    else:
        base = Path(os.environ.get("TMPDIR") or "/tmp")
        name = f"{STATE_DIR_NAME}-{os.getuid()}"

    root = base / name
    try:
        os.mkdir(root, 0o700)
    except FileExistsError:
        pass

    if not stat.S_ISDIR(os.lstat(root).st_mode):
        raise OSError("activation state root is not a directory")
    os.chmod(root, 0o700)
    return root


def _open_no_follow(path, flags, mode=0o600):
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags, mode)


@contextmanager
def _locked(claude_digest):
    root = _state_root()
    lock_path = root / f"{claude_digest}.lock"
    fd = _open_no_follow(lock_path, os.O_RDWR | os.O_CREAT)
    os.fchmod(fd, 0o600)
    lock_file = os.fdopen(fd, "r+b")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        yield root
    finally:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        lock_file.close()


def _record_path(root, claude_digest):
    return root / f"{claude_digest}.json"


def _read_record(root, claude_digest):
    try:
        fd = _open_no_follow(_record_path(root, claude_digest), os.O_RDONLY)
    except FileNotFoundError:
        return None

    with os.fdopen(fd, "rb") as state_file:
        raw = state_file.read(MAX_STATE_BYTES + 1)

    if len(raw) > MAX_STATE_BYTES:
        return None

    try:
        record = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None

    expected_keys = {"version", "claude_session_sha256", "memory_session_id"}
    if not isinstance(record, dict) or set(record) != expected_keys:
        return None
    if record["version"] != STATE_VERSION:
        return None
    if record["claude_session_sha256"] != claude_digest:
        return None
    if not _valid_id(record["memory_session_id"]):
        return None
    return record


def _write_record(root, claude_digest, memory_session_id):
    record = {
        "version": STATE_VERSION,
        "claude_session_sha256": claude_digest,
        "memory_session_id": memory_session_id,
    }
    encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_STATE_BYTES:
        raise ValueError("activation state exceeds bound")

    fd, temporary_path = tempfile.mkstemp(prefix=f".{claude_digest}.", dir=root)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as temporary_file:
            temporary_file.write(encoded)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, _record_path(root, claude_digest))
    finally:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass


def establish(claude_session_id, source):
    if not _valid_id(claude_session_id) or source not in VALID_SOURCES:
        return None
    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root:
            if source == "compact":
                record = _read_record(root, claude_digest)
                return record["memory_session_id"] if record else None

            memory_session_id = claude_session_id
            if source == "resume":
                memory_session_id = f"claude-run-{claude_digest[:12]}-{uuid.uuid4()}"
            _write_record(root, claude_digest, memory_session_id)
            return memory_session_id
    except STATE_ERRORS:
        return None

def resolve(claude_session_id):
    if not _valid_id(claude_session_id):
        return None
    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root:
            record = _read_record(root, claude_digest)
            return record["memory_session_id"] if record else None
    except STATE_ERRORS:
        return None

def prepare_end(claude_session_id):
    if not _valid_id(claude_session_id):
        return None
    claude_digest = _digest(claude_session_id)
    try:
        with _locked(claude_digest) as root:
            record = _read_record(root, claude_digest)
            if record is None:
                return None
            return claude_digest, record["memory_session_id"]
    except STATE_ERRORS:
        return None

def cleanup(claude_digest, memory_session_id):
    if (
        not isinstance(claude_digest, str)
        or len(claude_digest) != 64
        or any(char not in "0123456789abcdef" for char in claude_digest)
        or not _valid_id(memory_session_id)
    ):
        return False
    try:
        with _locked(claude_digest) as root:
            record = _read_record(root, claude_digest)
            if record is None or record["memory_session_id"] != memory_session_id:
                return False
            os.unlink(_record_path(root, claude_digest))
            return True
    except STATE_ERRORS:
        return False

def send_json(memory_url, endpoint, body):
    try:
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        result = subprocess.run(
            [
                "curl", "-sf", "-m", "2.0", "-X", "POST",
                memory_url.rstrip("/") + endpoint,
                "-H", "Content-Type: application/json",
                "--data-binary", "@-",
            ],
            input=encoded,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except (OSError, TypeError, UnicodeError, subprocess.SubprocessError):
        return False
```

State rules:

- Use `$XDG_RUNTIME_DIR/backplane-memory-hooks`; otherwise use `${TMPDIR:-/tmp}/backplane-memory-hooks-<uid>`.
- Reject a non-directory or symlink state root; create the owned subdirectory as `0700`.
- Name records `<sha256(claude_id)>.json`, locks `<digest>.lock`, and never use the raw ID in a path.
- Open locks without following symlinks where the platform supports `O_NOFOLLOW`, force `0600`, and hold `fcntl.flock(..., LOCK_EX)` for every read/write/delete decision.
- Store compact JSON containing only `version`, `claude_session_sha256`, and `memory_session_id`.
- Read no more than `MAX_STATE_BYTES + 1`; reject an oversized, malformed, wrong-version, wrong-digest, or invalid-ID record.
- Write through a `0600` temporary file in the state directory, flush it, and `os.replace` it atomically; remove a leftover temporary file on failure.
- Catch state and process errors at the shell boundary so every installed hook still exits zero.

- [ ] **Step 4: Run helper tests to verify GREEN**

Run:

```bash
devenv shell -- mix test apps/backplane_memory/test/hooks/hook_scripts_test.exs
python3 -m py_compile apps/backplane_memory/priv/hooks/activation_session.py
```

Expected: helper-contract tests pass and Python compilation exits 0.

- [ ] **Step 5: Commit the state helper**

```bash
git add apps/backplane_memory/priv/hooks/activation_session.py \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs
git diff --cached --check
git commit -m "feat(memory): add hook activation state"
```

### Task 3: Resolve activations in all installed hooks

**Files:**

- Modify: `apps/backplane_memory/priv/hooks/session-start.sh`
- Modify: `apps/backplane_memory/priv/hooks/session-end.sh`
- Modify: `apps/backplane_memory/priv/hooks/user-prompt-submit.sh`
- Modify: `apps/backplane_memory/priv/hooks/post-tool-use.sh`
- Modify: `apps/backplane_memory/priv/hooks/post-tool-use-failure.sh`
- Modify: `apps/backplane_memory/priv/hooks/pre-compact.sh`
- Modify: `apps/backplane_memory/priv/hooks/subagent-start.sh`
- Modify: `apps/backplane_memory/priv/hooks/subagent-stop.sh`
- Modify: `apps/backplane_memory/priv/hooks/stop.sh`
- Modify: `apps/backplane_memory/priv/hooks/post-commit.sh`
- Test: `apps/backplane_memory/test/hooks/hook_scripts_test.exs`
- Test: `apps/backplane_memory/test/mix/tasks/memory_connect_test.exs`

- [ ] **Step 1: Isolate state and curl captures in the test harness**

Give every hook invocation a unique `capture` and fake-bin directory while allowing a caller-supplied `runtime_dir` shared across lifecycle calls. Add these environment values:

```elixir
{"XDG_RUNTIME_DIR", runtime_dir},
{"TMPDIR", Path.join(tmp_dir, "tmp")},
{"HOOK_CURL_STARTED", Keyword.get(opts, :curl_started, "")},
{"HOOK_CURL_RELEASE", Keyword.get(opts, :curl_release, "")}
```

Extend fake curl so a race test can signal after body capture and wait until release:

```bash
[ -n "${HOOK_CURL_STARTED:-}" ] && : > "$HOOK_CURL_STARTED"
while [ -n "${HOOK_CURL_RELEASE:-}" ] && [ ! -e "$HOOK_CURL_RELEASE" ]; do
  sleep 0.01
done
```

Seed identity state only for existing non-lifecycle fixture tests. Tests that exercise missing state pass `seed: false`.

- [ ] **Step 2: Add failing lifecycle and translation tests**

Add `"source" => "startup"` to the SessionStart fixture. Treat a missing or unsupported SessionStart source as invalid input.

Add focused tests for:

```text
startup -> observation -> end -> resume -> observation -> end
compact reuses the active Memory ID
clear identity-maps Claude's new ID
all ten scripts put the resolved ID in the HTTP body
tool, failed-tool, subagent, and commit idempotency keys use the resolved ID
two Claude IDs sharing one runtime directory remain isolated
non-start and compact-without-state make no request
failed SessionEnd curl still removes the captured mapping
blocked SessionEnd + newer resume + release preserves the newer mapping
```

For the race, start SessionEnd in a Task, wait for `HOOK_CURL_STARTED`, run `SessionStart source=resume` for the same Claude ID, create `HOOK_CURL_RELEASE`, await SessionEnd, and assert the newer ID still resolves.

Update the installer test with:

```elixir
helper = Path.join(Path.dirname(session_start["command"]), "activation_session.py")
assert File.regular?(helper)
assert {:ok, %{access: access}} = File.stat(helper)
assert access in [:read, :read_write]
```

- [ ] **Step 3: Run integration tests to verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs \
  apps/backplane_memory/test/mix/tasks/memory_connect_test.exs
```

Expected: activation lifecycle/translation assertions fail because scripts still send raw Claude IDs and do not clean mapping state.

- [ ] **Step 4: Rewire the ten scripts with one parse and one Python process**

Each script locates the helper relative to itself, imports it before reading stdin, and replaces stdout/body piping with `send_json` in the same Python process:

```bash
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

python3 -c '
import json
import sys
sys.path.insert(0, sys.argv[1])
from activation_session import resolve, send_json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

session_id = resolve(data.get("session_id"))
prompt = data.get("prompt")
if session_id is None or not isinstance(prompt, str) or not prompt:
    sys.exit(0)

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": prompt,
    "tool_name": "user_prompt",
    "event_type": "conversation.user_message",
    "payload": {"prompt": prompt},
}
send_json(sys.argv[2], "/api/memory/observations", body)
' "$HOOKS_DIR" "$MEMORY_URL" >/dev/null 2>&1 || true
```

Apply these exact resolver and endpoint replacements while retaining each file's existing validation, body fields, event mapping, and payload construction byte-for-byte:

| Script | Import | Replace raw-ID assignment with | Endpoint |
|---|---|---|---|
| `session-start.sh` | `establish, send_json` | `session_id = establish(data.get("session_id"), data.get("source"))` | `/api/memory/session/start` |
| `session-end.sh` | `cleanup, prepare_end, send_json` | `prepared = prepare_end(data.get("session_id"))`; exit on `None`, otherwise `digest, session_id = prepared` | `/api/memory/session/end` |
| `user-prompt-submit.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `post-tool-use.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `post-tool-use-failure.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `pre-compact.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `subagent-start.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `subagent-stop.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `stop.sh` | `resolve, send_json` | `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |
| `post-commit.sh` | `resolve, send_json` | after the structural command check, `session_id = resolve(data.get("session_id"))` | `/api/memory/observations` |

Every resolver result must be checked with `if session_id is None: sys.exit(0)`. `session-start.sh` therefore accepts exactly `startup`, `resume`, `clear`, and `compact`; missing or unsupported sources return no ID and make no request. In the four scripts with idempotency keys, the existing f-strings automatically use the now-resolved `session_id` variable.

`session-end.sh` imports `prepare_end`, `send_json`, and `cleanup`; it captures `(digest, session_id)`, builds the end body, and uses:

```python
try:
    send_json(memory_url, "/api/memory/session/end", body)
finally:
    cleanup(digest, session_id)
```

All other body fields, explicit event types, payloads, two-second curl arguments, output suppression, recursion guards, and zero exit status remain unchanged.

- [ ] **Step 5: Run focused tests and syntax checks to verify GREEN**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs \
  apps/backplane_memory/test/mix/tasks/memory_connect_test.exs
for script in apps/backplane_memory/priv/hooks/*.sh; do bash -n "$script"; done
python3 -m py_compile apps/backplane_memory/priv/hooks/activation_session.py
```

Expected: all focused tests pass; every shell script and the helper compile successfully.

- [ ] **Step 6: Commit the hook lifecycle correction**

```bash
git add apps/backplane_memory/priv/hooks \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs \
  apps/backplane_memory/test/mix/tasks/memory_connect_test.exs
git diff --cached --check
git commit -m "fix(memory): isolate resumed hook activations"
```

### Task 4: Verify the packaged milestone

**Files:** No source changes expected.

- [ ] **Step 1: Run scoped Memory tests**

```bash
devenv shell -- mix test \
  apps/backplane_memory/test/hooks/hook_scripts_test.exs \
  apps/backplane_memory/test/mix/tasks/memory_connect_test.exs \
  apps/backplane_memory/test/backplane/memory/observations_test.exs \
  apps/backplane_api/test/backplane/api/memory_router_test.exs
devenv shell -- mix test apps/backplane_memory/test
```

Expected: zero failures.

- [ ] **Step 2: Verify static syntax and production packaging**

```bash
for script in apps/backplane_memory/priv/hooks/*.sh; do bash -n "$script"; done
python3 -m py_compile apps/backplane_memory/priv/hooks/activation_session.py
MIX_ENV=prod devenv shell -- mix release backplane --overwrite
find _build/prod/rel/backplane/lib -path '*/backplane_memory-*/priv/hooks/activation_session.py' -type f
```

Expected: syntax checks and release exit 0; `find` prints exactly one packaged helper path.

- [ ] **Step 3: Repeat the Memory V2 runtime acceptance**

With pipeline, events, and dual-write flags enabled in the disposable test database, demonstrate:

```text
flags off -> no events
startup -> sequence 1 session.started
tool completion -> sequence 2 tool.call.completed
same tool_use_id retry -> same linked observation/event
end -> sequence 3 session.ended and a closed stream
resume same Claude ID -> a distinct Memory session and open stream
resumed tool/end -> events stay in the second stream
one SummaryWorker job per ended Memory session
```

Reset all feature flags to false after the probe, even when an assertion fails.

- [ ] **Step 4: Run final change and diff checks**

```bash
git diff --check
git status --short
```

Run GitNexus staged/change detection before every commit. Because the current index does not map hook scripts or test helpers reliably, compare its output with direct `git diff --name-status`, focused tests, and release contents.

## Plan self-review

- Spec coverage: startup, resume, clear, compact, resolution across ten entrypoints, resolved idempotency, private bounded state, locking, atomic replacement, CAS cleanup, non-blocking failures, packaging, and runtime proof each map to an explicit task and assertion.
- Scope: the helper, ten hooks, two focused test files, and this plan are the only intended files; backend and release configuration stay unchanged.
- Placeholder scan: every implementation decision, interface, command, and expected result is concrete.
- Type consistency: helper calls consistently use the persistent Claude ID for lookup, its SHA-256 digest for filenames/cleanup locks, and the resolved Memory ID for HTTP bodies and idempotency keys.
