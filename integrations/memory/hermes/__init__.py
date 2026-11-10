"""Hermes memory provider backed by the Backplane host agent's global memory tools.

Reads and explicit writes call ``POST /memory/<agent_id>/call/<search|get|recent|
remember|forget>`` on the host agent. Conversation capture and mirrored native
memory writes go through a profile-local delivery journal first, so a host outage
never loses them and never raises into Hermes.
"""
from __future__ import annotations

from collections import OrderedDict
import contextvars
from datetime import datetime, timezone
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import threading
import time
import uuid
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

from .delivery import DeliveryJournal, canonical_json
from .context import render_context
from . import capture

try:
    from agent.memory_provider import MemoryProvider
except ImportError:
    class MemoryProvider:
        """Standalone test fallback; compatibility is tested separately."""

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://127.0.0.1:4222"
DEFAULT_AGENT_ID = "hermes"
# Tool calls and background delivery. Bounded, but long enough for gateway searches.
TIMEOUT = 20
# Synchronous prefetch; Hermes abandons an external prefetch after 8 seconds.
SEARCH_TIMEOUT = 5
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ERROR_CHARS = 200
SAFE_CODE = re.compile(r"[a-z_]{1,64}")
TERMINAL_STATUSES = {400, 401, 403, 404, 409, 413, 422}
METHODS = ("search", "get", "recent", "remember", "forget")
KINDS = ["fact", "procedure", "worklog", "note"]
DEFAULT_CONFIG = {
    "url": DEFAULT_BASE_URL, "agent_id": DEFAULT_AGENT_ID, "search_limit": 8,
    "context_token_budget": 1200, "cache_ttl": 5, "cache_entries": 32,
    "evidence_chars": 131072, "max_pending": 4096, "journal_bytes": 33554432,
}
BOUNDS = {
    "search_limit": (1, 50), "context_token_budget": (64, 100000), "cache_ttl": (1, 30),
    "cache_entries": (1, 128), "evidence_chars": (1024, 131072), "max_pending": (16, 10000),
    "journal_bytes": (1048576, 268435456),
}
INSTRUCTION_PATHS = (
    Path(__file__).resolve().parent.parent / "shared" / "INSTRUCTIONS.md",  # repository/release layout
    Path(__file__).resolve().parent / "INSTRUCTIONS.md",  # installed copy placed by the installer
)


def _secret(name):
    try:
        from agent.secret_scope import get_secret
    except ImportError:
        return os.environ.get(name)
    return get_secret(name)


def _validate_url(base):
    try:
        parsed = urlparse(base)
        return parsed.scheme in {"http", "https"} and bool(parsed.hostname) and not (parsed.username or parsed.password or parsed.query or parsed.fragment) and (parsed.port is None or 0 < parsed.port < 65536)
    except (ValueError, TypeError):
        return False


def _failure(label, code, http_status=None):
    """One content-free warning per failed request; the caller degrades."""
    response = {"ok": False, "error": code}
    if http_status is not None:
        response["http_status"] = http_status
    safe = code if SAFE_CODE.fullmatch(code) else "request_rejected"
    logger.warning("backplane-memory: %s failed: %s%s", label, safe, " (HTTP " + str(http_status) + ")" if http_status else "")
    return response


def _error_code(body, default):
    code = body.get("error") if isinstance(body, dict) else None
    return code[:MAX_ERROR_CHARS] if isinstance(code, str) and code.strip() else default


def _http(base, path, args=None, *, label=None, timeout=None):
    label = label or path
    if not _validate_url(base):
        return _failure(label, "invalid_url")
    request = Request(base.rstrip("/") + path, data=canonical_json(args or {}).encode(), headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(request, timeout=TIMEOUT if timeout is None else timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            return _failure(label, "invalid_response")
        body = json.loads(raw.decode())
        if not isinstance(body, dict) or body.get("ok") is not True:
            return _failure(label, _error_code(body, "invalid_response"))
        return body
    except HTTPError as error:
        try:
            try:
                raw = error.read(MAX_RESPONSE_BYTES + 1)
                body = json.loads(raw.decode()) if len(raw) <= MAX_RESPONSE_BYTES else None
            except (OSError, ValueError, UnicodeError):
                body = None
            code, status = _error_code(body, "http_error"), error.code
        finally:
            # Closing is also a redaction boundary: implicit HTTPError cleanup can
            # log its raw reason under Python ResourceWarning.
            error.close()
        return _failure(label, code, status)
    except (URLError, TimeoutError, OSError):
        return _failure(label, "request_failed")
    except (ValueError, UnicodeError):
        return _failure(label, "invalid_response")
    except Exception:
        return _failure(label, "request_failed")


def _call_path(agent_id, method):
    return "/memory/" + quote(agent_id, safe="") + "/call/" + quote(method, safe="")


def _post(base, agent_id, method, args=None, timeout=None):
    response = _http(base, _call_path(agent_id, method), args, label="memory " + method, timeout=timeout)
    if response.get("ok") and not isinstance(response.get("result"), dict):
        return _failure("memory " + method, "invalid_response")
    return response


def _unwrap(response):
    return response.get("result") if isinstance(response, dict) and response.get("ok") is True and isinstance(response.get("result"), dict) else None


def _tool_result(response):
    result = _unwrap(response)
    if result is not None:
        return result
    return {"success": False, **{k: v for k, v in response.items() if k in {"error", "http_status"}}}


def _load_config(home):
    path = home / "backplane-memory.json"
    if path.exists():
        try:
            stored = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as error:
            raise ValueError("invalid_provider_config") from error
        if not isinstance(stored, dict):
            raise ValueError("invalid_provider_config")
        unknown = sorted(key for key in stored if key not in DEFAULT_CONFIG)
        if unknown:
            # Settings written by older plugin versions are ignored, never applied.
            logger.warning("backplane-memory: ignoring unsupported config keys: %s", ", ".join(unknown))
        stored = {key: value for key, value in stored.items() if key in DEFAULT_CONFIG}
    else:
        stored = {}
    config = {**DEFAULT_CONFIG, **stored}
    for key, variable in (("url", "BACKPLANE_MEMORY_URL"), ("agent_id", "BACKPLANE_MEMORY_AGENT_ID")):
        value = _secret(variable)
        if value:
            config[key] = value
    if not _validate_url(config["url"]) or not isinstance(config["agent_id"], str) or not config["agent_id"].strip():
        raise ValueError("invalid_provider_config")
    for key, (low, high) in BOUNDS.items():
        value = config[key]
        if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
            raise ValueError("invalid_provider_config")
    return config


def _schema(name, description, properties, required=()):
    return {"name": name, "description": description, "parameters": {"type": "object", "properties": properties, "required": list(required)}}


SUBJECT = {"type": "object", "properties": {"type": {"type": "string"}, "key": {"type": "string"}}, "required": ["type", "key"]}
TOOLS = {
    "memory_search": ("search", _schema(
        "memory_search",
        "Backplane memory::search. Search memories shared by all of the user's agents and hosts; results show where each came from.",
        {"query": {"type": "string"}, "host": {"type": "string"}, "agent": {"type": "string"},
         "kind": {"type": "string", "enum": KINDS}, "subject": {"type": "string", "description": "Subject as type:key, e.g. repo:backplane"},
         "since": {"type": "string", "description": "ISO 8601 timestamp"}, "until": {"type": "string", "description": "ISO 8601 timestamp"},
         "include_inactive": {"type": "boolean", "default": False}, "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10}},
        ["query"])),
    "memory_get": ("get", _schema(
        "memory_get", "Backplane memory::get. Fetch one memory and its supersession history by id.",
        {"id": {"type": "string"}}, ["id"])),
    "memory_recent": ("recent", _schema(
        "memory_recent", "Backplane memory::recent. List recent worklog memories, newest first.",
        {"host": {"type": "string"}, "agent": {"type": "string"}, "since": {"type": "string", "description": "ISO 8601 timestamp"},
         "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20}})),
    "memory_remember": ("remember", _schema(
        "memory_remember",
        "Backplane memory::remember. Store something worth keeping: where something lives, how an operation is done, or what you did. The current session is attached automatically.",
        {"content": {"type": "string"}, "kind": {"type": "string", "enum": KINDS, "default": "note"}, "title": {"type": "string"},
         "subjects": {"type": "array", "items": SUBJECT, "description": "e.g. host:<name>, repo:<name>, service:<name>, path:<path>"},
         "property": {"type": "string"}, "tags": {"type": "array", "items": {"type": "string"}}},
        ["content"])),
    "memory_forget": ("forget", _schema(
        "memory_forget", "Backplane memory::forget. Mark a memory as outdated or forgotten, with a reason.",
        {"id": {"type": "string"}, "reason": {"type": "string"}}, ["id", "reason"])),
}


class BackplaneMemoryProvider(MemoryProvider):
    pre_compress_checkpoint_api_version = 2

    @property
    def name(self):
        return "backplane-memory"

    def is_available(self):
        if hasattr(self, "_config"):
            return _validate_url(self._base)
        try:
            home = getattr(self, "_home", Path(_secret("HERMES_HOME") or Path.home() / ".hermes"))
            _load_config(home)
            return True
        except (OSError, ValueError):
            return False

    def initialize(self, session_id, **kwargs):
        if hasattr(self, "_journal"):
            raise RuntimeError("provider_instance_already_bound")
        self._home = Path(kwargs.get("hermes_home") or _secret("HERMES_HOME") or Path.home() / ".hermes").expanduser().resolve()
        self._config = _load_config(self._home)
        self._base, self._agent_id = self._config["url"].rstrip("/"), self._config["agent_id"]
        parsed = urlparse(self._base)
        if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
            logger.warning("backplane-memory: plaintext_remote_transport")
        self._session_id, self._parent_session_id = session_id, ""
        self._context = {key: kwargs[key] for key in ("platform", "cwd", "repository_sources", "agent_identity") if kwargs.get(key)}
        self._automatic = kwargs.get("agent_context", "primary") == "primary"
        binding = {"url": self._base, "agent_id": self._agent_id, "hermes_home": str(self._home), "agent_identity": kwargs.get("agent_identity")}
        self._journal = DeliveryJournal(self._home / "backplane-memory" / "delivery.sqlite3", binding, max_pending=self._config["max_pending"], max_bytes=self._config["journal_bytes"])
        self._state_lock = threading.RLock()
        self._cache, self._prefetch_jobs = OrderedDict(), OrderedDict()
        self._generation = 0
        self._stopping, self._wake = threading.Event(), threading.Event()
        self._worker, self._worker_done, self._closed = None, False, False
        if self._automatic:
            with self._journal.transaction():
                capture.boundary(self, "session-start", session_id, dedup_key="session-start:" + session_id)
        self._start_worker()

    @staticmethod
    def _now():
        return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")

    def _capture_common(self, session_id):
        now = self._now()
        value = {"protocol": "hermes_capture.v1", "session_id": session_id, "agent_id": self._agent_id, "installation_id": self._journal.installation_id, "profile_id": self._journal.profile_id, "occurred_at": now, "captured_at": now}
        for key in ("cwd", "repository_sources"):
            if self._context.get(key):
                value[key] = self._context[key]
        parent = self._journal.get("session-parent:" + session_id, "")
        if parent:
            value["parent_session_id"] = parent
        return value

    def _invalidate_context(self):
        with self._state_lock:
            self._generation += 1
            self._cache.clear()
            self._prefetch_jobs.clear()

    # -- setup ---------------------------------------------------------------

    def get_config_schema(self):
        fields = [("url", "Host agent URL", DEFAULT_BASE_URL, "BACKPLANE_MEMORY_URL"), ("agent_id", "Logical agent URL identifier", DEFAULT_AGENT_ID, "BACKPLANE_MEMORY_AGENT_ID")]
        return [{"key": key, "description": description, "default": default, "env_var": variable} for key, description, default, variable in fields] + [
            {"key": "search_limit", "description": "Memories searched for automatic context each turn", "default": 8, "type": "integer", "minimum": 1, "maximum": 50},
            {"key": "context_token_budget", "description": "Maximum rendered automatic context budget", "default": 1200, "type": "integer", "minimum": 64, "maximum": 100000}]

    def save_config(self, values, hermes_home):
        if any(key not in DEFAULT_CONFIG for key in values):
            raise ValueError("invalid_provider_config")
        home = Path(hermes_home).expanduser().resolve()
        home.mkdir(parents=True, exist_ok=True)
        path = home / "backplane-memory.json"
        existing = json.loads(path.read_text()) if path.exists() else {}
        # Rewriting drops settings older plugin versions stored.
        merged = {key: value for key, value in {**existing, **values}.items() if key in DEFAULT_CONFIG}
        from tempfile import NamedTemporaryFile
        with NamedTemporaryFile("w", encoding="utf-8", dir=home, prefix=".backplane-memory-", delete=False) as stream:
            temporary = Path(stream.name)
            try:
                json.dump(merged, stream, ensure_ascii=False, indent=2)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)

    def system_prompt_block(self):
        """The canonical resident instruction shared by every Backplane memory client."""
        cached = getattr(self, "_instructions", None)
        if cached is not None:
            return cached
        for path in INSTRUCTION_PATHS:
            try:
                self._instructions = path.read_text(encoding="utf-8")
                return self._instructions
            except OSError:
                continue
        logger.warning("backplane-memory: INSTRUCTIONS.md is missing")
        self._instructions = ""
        return ""

    # -- tools ---------------------------------------------------------------

    def get_tool_schemas(self):
        return [schema for _method, schema in TOOLS.values()]

    def handle_tool_call(self, name, args, **kwargs):
        if kwargs.get("hermes_home") and Path(kwargs["hermes_home"]).expanduser().resolve() != self._home:
            return json.dumps({"success": False, "error": "profile_binding_mismatch"})
        if kwargs.get("agent_identity") and kwargs["agent_identity"] != self._context.get("agent_identity"):
            return json.dumps({"success": False, "error": "profile_binding_mismatch"})
        if name not in TOOLS:
            return json.dumps({"success": False, "error": "unknown_tool"})
        method, schema = TOOLS[name]
        args = args if isinstance(args, dict) else {}
        parameters = schema["parameters"]
        if any(args.get(key) in (None, "") for key in parameters["required"]):
            return json.dumps({"success": False, "error": "invalid_arguments"})
        payload = {key: value for key, value in args.items() if key in parameters["properties"]}
        if method == "remember":
            payload["session_id"] = self._session_id
        response = _post(self._base, self._agent_id, method, payload)
        if method in {"remember", "forget"}:
            self._invalidate_context()
        return json.dumps(_tool_result(response), ensure_ascii=False)

    # -- automatic context ---------------------------------------------------

    def queue_prefetch(self, query, *, session_id=""):
        if getattr(self, "_closed", True) or not isinstance(query, str) or not query.strip() or len(query) > 16384:
            return
        key = (session_id or self._session_id, query, self._generation)
        with self._state_lock:
            self._prefetch_jobs[key] = None
            while len(self._prefetch_jobs) > self._config["cache_entries"]:
                self._prefetch_jobs.popitem(last=False)
        self._wake.set()

    def prefetch(self, query, *, session_id=""):
        """Cached context for this exact turn text, else one bounded search."""
        if getattr(self, "_closed", True) or not isinstance(query, str) or not query.strip() or len(query) > 16384:
            return ""
        try:
            key = (session_id or self._session_id, query, self._generation)
            with self._state_lock:
                cached = self._cache.get(key)
                if cached and cached[0] > time.monotonic():
                    return cached[1]
            return self._fetch_context(key, timeout=SEARCH_TIMEOUT)
        except Exception:
            logger.warning("backplane-memory: prefetch failed")
            return ""

    def _fetch_context(self, key, _unused=None, *, timeout=None):
        response = _post(self._base, self._agent_id, "search", {"query": key[1], "limit": self._config["search_limit"]}, timeout=timeout)
        result = _unwrap(response)
        if result is None:
            return ""
        text = render_context(result, self._config["context_token_budget"])
        with self._state_lock:
            if key[2] == self._generation:
                self._cache[key] = (time.monotonic() + self._config["cache_ttl"], text)
                while len(self._cache) > self._config["cache_entries"]:
                    self._cache.popitem(last=False)
        return text

    # -- automatic writes ----------------------------------------------------

    def on_memory_write(self, action, target, content, metadata=None, **kwargs):
        """Mirror a built-in memory write as a durable, idempotent memory::remember note.

        Removals are not mirrored: the native entry carries no Backplane record id.
        """
        if not self._automatic or self._closed or action not in {"add", "replace"}:
            return
        if not isinstance(content, str) or not content.strip():
            return
        metadata = metadata if isinstance(metadata, dict) else {}
        session_id = metadata.get("session_id") if isinstance(metadata.get("session_id"), str) and metadata.get("session_id") else self._session_id
        event_id = str(uuid.uuid4())
        payload = {"content": content, "kind": "note", "writer": "agent", "session_id": session_id,
                   "tags": ["hermes:" + str(target)], "request_key": "hermes:" + event_id}
        try:
            self._journal.enqueue(event_id, _call_path(self._agent_id, "remember"), payload)
        except Exception:
            logger.warning("backplane-memory: memory write could not be queued")
            return
        self._invalidate_context()
        self._wake.set()

    # -- capture -------------------------------------------------------------

    def sync_turn(self, user_content, assistant_content, *, session_id="", messages=None, turn_author=None):
        if not self._automatic:
            return
        self._ensure_open()
        session_id = session_id or self._session_id
        if not session_id:
            raise ValueError("capture_session_required")
        rows = messages if messages is not None else [{"role": "user", "content": user_content}, {"role": "assistant", "content": assistant_content}]
        capture.capture_messages(self, rows, session_id, author=turn_author, turn_user_content=user_content, align_legacy=messages is not None)
        self._wake.set()

    def on_pre_compress(self, messages, *, require_checkpoint=False):
        self._ensure_open()
        if not self._automatic:
            raise RuntimeError("checkpoint_disabled_for_nonprimary_context")
        if not self._session_id:
            raise ValueError("capture_session_required")
        ids = capture.capture_messages(self, messages, self._session_id, checkpoint=True)
        self._wake.set()
        digest = hashlib.sha256(canonical_json(ids).encode()).hexdigest()
        return "Backplane durable local checkpoint " + digest + " (" + str(len(ids)) + " direct evidence rows; host delivery may be pending). Evidence event references: " + ", ".join(ids[:8]) + ("; additional references retained in the delivery journal." if len(ids) > 8 else ".")

    def on_session_end(self, messages):
        if not self._automatic or self._closed:
            return
        ids = capture.capture_messages(self, messages, self._session_id)
        with self._journal.transaction():
            watermark = hashlib.sha256(canonical_json(ids).encode()).hexdigest()
            capture.boundary(self, "session-end", self._session_id, lifecycle={"reason": "session_end"}, dedup_key="session-end:" + self._session_id + ":" + watermark)
        self._wake.set()

    def on_session_switch(self, new_session_id, *, parent_session_id="", reset=False, rewound=False, **kwargs):
        self._ensure_open()
        if not new_session_id:
            return
        self._journal.set("session-parent:" + new_session_id, parent_session_id)
        with self._state_lock:
            self._session_id, self._parent_session_id = new_session_id, parent_session_id
            self._invalidate_context()
        if self._automatic:
            with self._journal.transaction():
                capture.boundary(self, "session-start", new_session_id, lifecycle={"reason": str(kwargs.get("reason", "session_switch")), "reset": bool(reset), "rewound": bool(rewound)})
                self._journal.set("session-start:" + new_session_id, "switched")
        self._wake.set()

    def _ensure_open(self):
        if self._closed:
            raise RuntimeError("provider_shut_down")

    # -- delivery ------------------------------------------------------------

    def delivery_status(self):
        value = self._journal.status() if not self._closed else dict(self._final_status)
        return {**value, "worker_alive": bool(self._worker and self._worker.is_alive())}

    def _start_worker(self):
        try:
            from agent.memory_provider import spawn_context_thread
            worker = spawn_context_thread(self._worker_loop, name="backplane-memory-delivery", daemon=True)
        except ImportError:
            context = contextvars.copy_context()
            worker = threading.Thread(target=lambda: context.run(self._worker_loop), name="backplane-memory-delivery", daemon=True)
        self._worker = worker
        worker.start()

    def _settle_capture(self, row):
        response = _http(self._base, "/capture/v1/status", {"event_ids": [row["event_id"]]}, label="capture status")
        result = _unwrap(response)
        if result and result.get("protocol") != "hermes_capture.v1":
            result = None
        item = next((item for item in (result or {}).get("items", []) if isinstance(item, dict) and item.get("event_id") == row["event_id"]), {})
        status = {"host_accepted": "pending", "canonical_committed": "committed", "rejected": "rejected"}.get(item.get("status"))
        if status:
            self._journal.accept(row["event_id"], {**item, "status": status})
            return True
        self._journal.retry(row["event_id"], response.get("error", "status_unknown"))
        return False

    def _send(self, row):
        payload = json.loads(row["payload"])
        is_capture = row["path"].startswith("/capture/")
        label = "capture " + row["path"].rsplit("/", 1)[-1] if is_capture else "memory remember"
        response = _http(self._base, row["path"], payload, label=label)
        if response.get("ok"):
            if is_capture and response.get("status") in {"accepted", "duplicate"} and response.get("event_id") == row["event_id"]:
                self._journal.accept(row["event_id"], {"status": "pending", "event_id": row["event_id"]})
                return True
            result = response.get("result")
            if not is_capture and isinstance(result, dict):
                receipt = {"status": "committed", "event_id": row["event_id"]}
                if isinstance(result.get("id"), str):
                    receipt["canonical_id"] = result["id"]
                self._journal.accept(row["event_id"], receipt)
                return True
            self._journal.retry(row["event_id"], "invalid_response")
            return False
        if response.get("http_status") in TERMINAL_STATUSES:
            self._journal.reject(row["event_id"], "request_rejected")
            return True
        self._journal.retry(row["event_id"], response.get("error", "request_failed")[:64])
        return False

    def _deliver_once(self):
        rows = self._journal.pending(now=float("inf"), limit=32)
        for row in rows:
            if self._stopping.is_set():
                break
            if row["next_at"] > time.time():
                if row["state"] == "local_pending":
                    break
                continue
            if row["state"] == "host_accepted":
                self._settle_capture(row)
            elif not self._send(row):
                # Preserve local stage order behind a retrying row.
                break
        return bool(rows)

    def _worker_loop(self):
        try:
            while not self._stopping.is_set():
                try:
                    self._deliver_once()
                    if self._stopping.is_set():
                        break
                    with self._state_lock:
                        job = self._prefetch_jobs.popitem(last=False) if self._prefetch_jobs else None
                    if job:
                        self._fetch_context(*job)
                    self._journal.prune()
                except Exception:
                    # Keep diagnostics content-safe. The durable rows stay available.
                    logger.warning("backplane-memory: delivery_worker_failed")
                self._wake.wait(0.25)
                self._wake.clear()
        finally:
            with self._journal.lock:
                self._worker_done = True
                if self._closed:
                    self._journal.close()

    def shutdown(self):
        if not hasattr(self, "_journal") or self._closed:
            return
        worker = self._worker
        if worker:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and self._journal.status()["local_pending"] and worker.is_alive():
                self._wake.set()
                time.sleep(0.02)
            self._stopping.set()
            self._wake.set()
            worker.join(timeout=3)
        # Coordinate ownership with the worker finalizer. A thread can still be
        # alive after its finalizer has finished; is_alive alone leaks that DB.
        with self._journal.lock:
            self._final_status = self._journal.status()
            self._closed = True
            if not worker or self._worker_done or not worker.is_alive():
                self._journal.close()

    def flush(self, *, timeout=10, canonical=False):
        """Wait for tracked delivery, without converting host acceptance into canonical success."""
        self._ensure_open()
        deadline = time.monotonic() + max(0, min(float(timeout), 300))
        while True:
            status = self.delivery_status()
            remaining = status["local_pending"] + (status["host_accepted"] if canonical else 0)
            if status["rejected"] or not remaining or time.monotonic() >= deadline:
                return {"success": not remaining and not status["rejected"], **status}
            self._wake.set()
            time.sleep(0.05)


def register(ctx):
    ctx.register_memory_provider(BackplaneMemoryProvider())
