"""
Backplane Memory provider for Hermes Agent.

Talks to the local Backplane host agent's Memory HTTP API
(default `http://127.0.0.1:4222/memory/<agent_id>/...`), which proxies
every call through the host agent's authenticated WebSocket channel
to the Backplane hub.

Drop this folder into ~/.hermes/plugins/backplane-memory/ or install via:

    hermes plugin install backplane-memory

Requires the host agent running locally:

    BACKPLANE_HOST_AGENT_CONFIG=~/.config/backplane/host_agent.yaml mix agent.run

with `agent.http_port` set in the YAML.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

try:
    from agent.memory_provider import MemoryProvider
except ImportError:
    from abc import ABC, abstractmethod

    class MemoryProvider(ABC):
        @property
        @abstractmethod
        def name(self) -> str: ...
        @abstractmethod
        def is_available(self) -> bool: ...
        @abstractmethod
        def initialize(self, session_id: str, **kwargs: Any) -> None: ...
        @abstractmethod
        def get_tool_schemas(self) -> list[dict]: ...
        @abstractmethod
        def handle_tool_call(self, name: str, args: dict) -> str: ...
        def get_config_schema(self) -> list[dict]: return []
        def save_config(self, values: dict, hermes_home: str) -> None: pass
        def system_prompt_block(self) -> str: return ""
        def prefetch(self, query: str, **kwargs: Any) -> str: return ""
        def queue_prefetch(self, query: str, **kwargs: Any) -> None: pass
        def sync_turn(self, user: str, assistant: str, **kwargs: Any) -> None: pass
        def on_session_end(self, messages: list, **kwargs: Any) -> None: pass
        def on_pre_compress(self, messages: list, **kwargs: Any) -> None: pass
        def on_memory_write(self, action: str, target: str, content: str, **kwargs: Any) -> None: pass
        def shutdown(self, **kwargs: Any) -> None: pass


DEFAULT_BASE_URL = "http://127.0.0.1:4222"
DEFAULT_AGENT_ID = "hermes"
TIMEOUT = 5
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}
_plaintext_warned = False
ERROR_CODES = {
    "invalid_scope", "unknown_scope", "memory_scope_mismatch", "invalid_arguments", "invalid_request",
    "unauthorized", "forbidden", "access_denied", "not_found",
}


def _preload_dotenv() -> None:
    """Read ~/.config/backplane/host_agent_client.env at import time."""
    candidates: list[Path] = []
    home = os.environ.get("HOME")
    if home:
        candidates.append(Path(home) / ".config" / "backplane" / "host_agent_client.env")
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        candidates.append(Path(xdg) / "backplane" / "host_agent_client.env")
    for path in candidates:
        try:
            if not path.is_file():
                continue
            for raw in path.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key:
                    os.environ.setdefault(key, value)
        except (OSError, UnicodeDecodeError):
            continue


_preload_dotenv()


def _validate_url(base: str) -> bool:
    if not base:
        return False
    try:
        parsed = urlparse(base)
        _ = parsed.port
    except ValueError:
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    return bool(parsed.hostname)


def _is_loopback(base: str) -> bool:
    try:
        host = (urlparse(base).hostname or "").lower()
    except ValueError:
        return False
    return host in LOOPBACK_HOSTS


def _warn_plaintext_remote(base: str) -> None:
    global _plaintext_warned
    if _plaintext_warned:
        return
    if urlparse(base).scheme == "https" or _is_loopback(base):
        return
    _plaintext_warned = True
    print(
        f"backplane-memory: sending requests in plaintext to non-loopback host {base}. "
        "Tunnel over SSH or set BACKPLANE_MEMORY_URL to an https:// URL.",
        file=sys.stderr,
    )


def _post(
    base: str,
    agent_id: str,
    method: str,
    args: dict | None = None,
) -> dict:
    if not _validate_url(base):
        return _failure("invalid_url")
    _warn_plaintext_remote(base)
    url = f"{base.rstrip('/')}/memory/{quote(agent_id, safe='')}/call/{quote(method, safe='')}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(args or {}).encode()
    req = Request(url, data=data, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            response = json.loads(resp.read().decode())
            if not isinstance(response, dict):
                return _failure("invalid_response")
            if response.get("ok") is False:
                return _failure(_error_code(response))
            if response.get("ok") is not True or not isinstance(response.get("result"), dict):
                return _failure("invalid_response")
            return response
    except HTTPError as error:
        try:
            body = json.loads(error.read().decode())
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            body = None
        return _failure(_error_code(body, "http_error"), error.code)
    except (URLError, TimeoutError, OSError):
        return _failure("request_failed")
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _failure("invalid_response")


def _error_code(body: Any, default: str = "request_failed") -> str:
    code = body.get("error") if isinstance(body, dict) else None
    return code if isinstance(code, str) and code in ERROR_CODES else default


def _failure(code: str, http_status: int | None = None) -> dict:
    response = {"ok": False, "error": code}
    if http_status is not None:
        response["http_status"] = http_status
    print(f"backplane-memory: {code}" + (f" (HTTP {http_status})" if http_status else ""), file=sys.stderr)
    return response


def _post_bg(base: str, agent_id: str, method: str, args: dict | None = None) -> None:
    t = threading.Thread(
        target=_post, args=(base, agent_id, method, args), daemon=True
    )
    t.start()


def _unwrap(response: dict | None) -> dict | None:
    """Extract `result` from a successful backplane reply."""
    if not isinstance(response, dict) or response.get("ok") is not True:
        return None
    result = response.get("result")
    return result if isinstance(result, dict) else None


def _tool_result(response: dict | None) -> dict:
    result = _unwrap(response)
    if result is not None:
        return result
    failure = {"success": False, "error": (response or {}).get("error", "request_failed")}
    if response and "http_status" in response:
        failure["http_status"] = response["http_status"]
    return failure


def _is_provisional(entry: dict) -> bool:
    return entry.get("provisional") is True or entry.get("authority") == "provisional"


def _format_memory_entry(entry: dict) -> str:
    content = entry.get("content") or ""
    content = content.strip()
    return f"[pending local memory] {content}" if content and _is_provisional(entry) else content


class BackplaneMemoryProvider(MemoryProvider):

    @property
    def name(self) -> str:
        return "backplane-memory"

    def is_available(self) -> bool:
        base = getattr(self, "_base", os.environ.get("BACKPLANE_MEMORY_URL", DEFAULT_BASE_URL))
        agent_id = getattr(self, "_agent_id", os.environ.get("BACKPLANE_MEMORY_AGENT_ID", DEFAULT_AGENT_ID))
        return _unwrap(_post(base, agent_id, "list", {"limit": 1})) is not None

    def initialize(self, session_id: str, **kwargs: Any) -> None:
        self._base = os.environ.get("BACKPLANE_MEMORY_URL", DEFAULT_BASE_URL)
        self._agent_id = os.environ.get("BACKPLANE_MEMORY_AGENT_ID", DEFAULT_AGENT_ID)
        self._session_id = session_id
        # Scope is bound by the authenticated host configuration, never by cwd.

    def get_config_schema(self) -> list[dict]:
        return [
            {
                "key": "url",
                "description": "Backplane host agent Memory API URL",
                "default": DEFAULT_BASE_URL,
                "env_var": "BACKPLANE_MEMORY_URL",
            },
            {
                "key": "agent_id",
                "description": "Logical agent id used in /memory/:agent_id/ URLs",
                "default": DEFAULT_AGENT_ID,
                "env_var": "BACKPLANE_MEMORY_AGENT_ID",
            },
        ]

    def save_config(self, values: dict, hermes_home: str) -> None:
        config_path = Path(hermes_home) / "backplane-memory.json"
        config_path.write_text(json.dumps(values, indent=2))

    def system_prompt_block(self) -> str:
        result = _unwrap(
            _post(self._base, self._agent_id, "list", {"limit": 10})
        )
        if not result:
            return ""
        # Render the pending sideband separately; preserve canonical list pagination.
        rows = result.get("results", [])
        canonical = [row for row in rows if not _is_provisional(row)]
        pending = [row for row in rows if _is_provisional(row)]
        pending += result.get("provisional_results", [])
        lines = []
        for title, entries in [
            ("Recent memories from backplane:", canonical),
            ("Pending local memories (awaiting canonical acknowledgment):", pending),
        ]:
            formatted = [_format_memory_entry(row) for row in entries]
            formatted = [entry for entry in formatted if entry]
            if formatted:
                lines.append(title)
                lines.extend(f"- {entry}" for entry in formatted)
        return "\n".join(lines)

    def prefetch(self, query: str, **kwargs: Any) -> str:
        result = _unwrap(
            _post(
                self._base,
                self._agent_id,
                "recall",
                {"query": query, "limit": 5},
            )
        )
        if not result or not result.get("results"):
            return ""
        lines = []
        for row in result["results"][:5]:
            entry = _format_memory_entry(row)
            if entry:
                lines.append(f"- {entry[:200]}")
        return "\n".join(lines) if lines else ""

    def queue_prefetch(self, query: str, **kwargs: Any) -> None:
        _post_bg(
            self._base,
            self._agent_id,
            "recall",
            {"query": query, "limit": 3},
        )

    def get_tool_schemas(self) -> list[dict]:
        return [
            {
                "name": "memory_recall",
                "description": "Search backplane memory by query (cosine similarity).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"},
                        "limit": {"type": "integer", "default": 10},
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "memory_save",
                "description": "Save a fact, decision, or pattern to backplane memory.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "content": {"type": "string", "description": "What to remember"},
                        "type": {
                            "type": "string",
                            "enum": ["working", "episodic", "semantic", "procedural"],
                            "default": "semantic",
                        },
                        "tags": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["content"],
                },
            },
            {
                "name": "memory_list",
                "description": "List recent memories, optionally filtered by tag/scope.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "tag": {"type": "string"},
                        "scope": {"type": "string", "description": "Host-authorized scope key, not a working directory"},
                        "limit": {"type": "integer", "default": 20},
                    },
                },
            },
            {
                "name": "memory_forget",
                "description": "Soft-delete a memory by id.",
                "parameters": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
            },
        ]

    def handle_tool_call(self, name: str, args: dict) -> str:
        if name == "memory_recall":
            payload = {"query": args["query"], "limit": args.get("limit", 10)}
            return json.dumps(_tool_result(_post(self._base, self._agent_id, "recall", payload)))

        if name == "memory_save":
            payload = {
                "content": args["content"],
                "type": args.get("type", "semantic"),
                "tags": args.get("tags") or [],
                "session_id": self._session_id,
            }
            return json.dumps(_tool_result(_post(self._base, self._agent_id, "remember", payload)))

        if name == "memory_list":
            payload = {
                "limit": args.get("limit", 20),
            }
            if args.get("scope"):
                payload["scope"] = args["scope"]
            if args.get("tag"):
                payload["tag"] = args["tag"]
            return json.dumps(_tool_result(_post(self._base, self._agent_id, "list", payload)))

        if name == "memory_forget":
            return json.dumps(_tool_result(_post(self._base, self._agent_id, "forget", {"id": args["id"]})))

        return json.dumps({"error": f"Unknown tool: {name}"})

    def sync_turn(self, user: str, assistant: str, **kwargs: Any) -> None:
        if not user and not assistant:
            return
        content = (
            f"User: {user[:500].strip()}\n\n"
            f"Assistant: {assistant[:2000].strip()}"
        )
        _post_bg(
            self._base,
            self._agent_id,
            "remember",
            {
                "content": content,
                "type": "episodic",
                "session_id": kwargs.get("session_id", self._session_id),
                "metadata": {
                    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "source": "hermes.sync_turn",
                },
            },
        )

    def on_session_end(self, messages: list, **kwargs: Any) -> None:
        # No session lifecycle in backplane memory; turns are independent.
        pass

    def on_pre_compress(self, messages: list, **kwargs: Any) -> None:
        last_user = ""
        for m in reversed(messages):
            if isinstance(m, dict) and m.get("role") == "user":
                content = m.get("content")
                if isinstance(content, str):
                    last_user = content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            last_user = block.get("text", "")
                            break
                if last_user:
                    break
        if not last_user:
            return
        result = _unwrap(
            _post(
                self._base,
                self._agent_id,
                "recall",
                {"query": last_user[:500], "limit": 5},
            )
        )
        rows = (result or {}).get("results", [])
        if not rows:
            return
        block_lines = ["[backplane memory: relevant context before compaction]"]
        for row in rows:
            entry = _format_memory_entry(row)
            if entry:
                block_lines.append(f"- {entry[:300]}")
        messages.insert(0, {"role": "user", "content": "\n".join(block_lines)})

    def on_memory_write(self, action: str, target: str, content: str, **kwargs: Any) -> None:
        if action not in ("add", "update") or not content:
            return
        _post_bg(
            self._base,
            self._agent_id,
            "remember",
            {
                "content": content,
                "type": "semantic",
                "tags": [target] if target else [],
                "metadata": {"source": f"hermes.memory_write.{action}"},
            },
        )

    def shutdown(self, **kwargs: Any) -> None:
        pass


def register(ctx: Any) -> None:
    ctx.register_memory_provider(BackplaneMemoryProvider())
