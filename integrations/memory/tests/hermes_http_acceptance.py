"""Manual Hermes acceptance peer; invoked only by test/hermes_memory_live_acceptance.exs.

The JSON-lines protocol carries synthetic fixture identities and safe results only.
Use the real Hermes interpreter: missing public APIs are an environment blocker.
No gateway token or upstream API key is accepted by this process.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class CheckFailure(Exception):
    pass


def require(value, code):
    if not value:
        raise CheckFailure(code)


class Scenario:
    def __init__(self, root, base_url, marker, timeout):
        require(root.is_dir() and not root.is_symlink(), "unsafe_fixture_home")
        uri = urlparse(base_url)
        require(uri.scheme == "http" and uri.hostname == "127.0.0.1"
                and uri.port and uri.port not in {4220, 4221, 4222}, "unsafe_host_url")
        require(len(marker) >= 8 and all(c in "0123456789abcdef" for c in marker), "invalid_marker")
        self.root, self.base, self.marker, self.timeout = root, base_url, marker, timeout
        self.providers = {}
        self.state_path = root / "scenario.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        self.old = "Fixture " + marker + ": deployment status color is cobalt."
        self.current = "Fixture " + marker + ": deployment status color is amber."
        self.outage = "Fixture " + marker + ": restart verification uses a durable journal."
        self.budget = 512
        self.plugin = None

    def save(self):
        self.state_path.write_text(json.dumps(self.state, sort_keys=True), encoding="utf-8")
        self.state_path.chmod(0o600)

    def boot(self):
        # These imports must resolve to Hermes itself, never a fixture shim.
        try:
            from agent.memory_provider import MemoryProvider
            from agent.memory_manager import redact_for_egress
        except ImportError:
            raise CheckFailure("BLOCKED_ENV:hermes_public_api_unavailable") from None
        require(callable(redact_for_egress), "BLOCKED_ENV:hermes_egress_api_unavailable")
        name = "backplane_live_" + uuid.uuid4().hex
        source = Path(__file__).resolve().parents[1] / "hermes" / "__init__.py"
        spec = importlib.util.spec_from_file_location(name, source)
        self.plugin = importlib.util.module_from_spec(spec)
        sys.modules[name] = self.plugin
        spec.loader.exec_module(self.plugin)
        require(issubclass(self.plugin.BackplaneMemoryProvider, MemoryProvider), "hermes_contract_fallback")
        identities = {}
        for label in ("a", "b"):
            home = self.root / label
            native = home / "memories"
            native.mkdir(parents=True, exist_ok=True, mode=0o700)
            for target in ("MEMORY.md", "USER.md"):
                path = native / target
                if not path.exists():
                    path.write_text("", encoding="utf-8")
            (home / "backplane-memory.json").write_text(json.dumps({
                "url": self.base, "agent_id": "hermes", "context_token_budget": self.budget,
                "relevance_mode": "server", "cache_ttl": 1,
            }), encoding="utf-8")
            provider = self.plugin.BackplaneMemoryProvider()
            provider.initialize(self.session(label), hermes_home=str(home),
                                cwd=str(self.root / "synthetic-project"))
            self.providers[label] = provider
            require(provider.delivery_status()["native_egress"] == "available",
                    "BLOCKED_ENV:hermes_egress_api_unavailable")
            identities[label] = provider._source("memory")
        previous = self.state.get("identities")
        if previous:
            require(previous == identities, "provider_restart_changed_source_identity")
        self.state["identities"] = identities
        self.save()
        return {"identities": identities, "sessions": [self.session(x) for x in ("a", "b")]}

    def session(self, label):
        return "hermes-live-" + self.marker + "-" + label

    def settle(self):
        results = {}
        for label, provider in self.providers.items():
            result = provider.flush(timeout=self.timeout, canonical=True)
            require(result["success"], "canonical_delivery_unsettled:" + label)
            results[label] = {key: result[key] for key in (
                "local_pending", "host_accepted", "canonical_committed", "rejected",
                "capture_deferred", "pending_reconciliation")}
        return {"delivery": results}

    def native(self, label, content, action, previous=None):
        provider = self.providers[label]
        (provider._home / "memories" / "MEMORY.md").write_text(content, encoding="utf-8")
        metadata = {"session_id": self.session(label), "tool_call_id": "same-batch"}
        if previous is not None:
            metadata["previous_content"] = previous
        provider.on_memory_write(action, "memory", content, metadata=metadata)

    def listed(self):
        result = json.loads(self.providers["a"].handle_tool_call("memory_list", {"limit": 100}))
        require(result.get("success") is not False and not result.get("error")
                and isinstance(result.get("results"), list), "canonical_list_failed")
        return result["results"]

    def present(self, content):
        return [row for row in self.listed() if row.get("content") == content]

    def native_add(self):
        self.native("a", self.old, "add")
        self.native("b", self.old, "add")
        self.settle()
        rows = self.present(self.old)
        require(len(rows) == 1, "independent_sources_not_canonically_deduplicated")
        self.state["original_id"] = rows[0]["id"]
        # Inspect the journal through its owning connection, under its lock.
        journal = self.providers["a"]._journal
        with journal.lock:
            row = journal.db.execute(
                "SELECT event_id,path,payload,receipt FROM delivery WHERE path LIKE '%/source_mutate' ORDER BY queue_sequence LIMIT 1"
            ).fetchone()
            require(row is not None, "source_mutation_delivery_missing")
            self.state["replay"] = dict(row)
        self.save()
        return {"canonical_id": rows[0]["id"], "identities": self.state["identities"]}

    def native_replace(self):
        self.native("a", self.current, "replace", self.old)
        self.settle()
        require(len(self.present(self.current)) == 1, "replacement_not_visible")
        require(len(self.present(self.old)) == 1, "replacement_withdrew_independent_source")
        return {"replacement_id": self.present(self.current)[0]["id"]}

    def native_withdraw(self):
        self.native("a", "", "remove", self.current)
        self.settle()
        require(not self.present(self.current), "sole_source_withdrawal_still_visible")
        require(len(self.present(self.old)) == 1, "withdrawal_removed_independent_source")
        return {"preserved_id": self.state["original_id"]}

    def native_correct(self):
        self.native("b", self.current, "replace", self.old)
        self.settle()
        require(not self.present(self.old), "old_native_value_still_visible")
        rows = self.present(self.current)
        require(len(rows) == 1, "corrected_native_value_missing")
        self.state["current_id"] = rows[0]["id"]
        self.save()
        return {"canonical_id": rows[0]["id"]}

    def request(self, path, payload):
        request = Request(self.base + path, json.dumps(payload).encode(),
                          {"Content-Type": "application/json"}, method="POST")
        try:
            with urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read(2 * 1024 * 1024))
        except HTTPError as error:
            return error.code, json.loads(error.read(2 * 1024 * 1024))
        except (URLError, TimeoutError):
            raise CheckFailure("host_transport_unavailable") from None

    def immutable_replay(self):
        replay = self.state["replay"]
        payload = json.loads(replay["payload"])
        before = self.listed()
        status, response = self.request(replay["path"], payload)
        require(status == 200 and response.get("ok") is True, "immutable_replay_rejected")
        receipt = response.get("result", {})
        original = json.loads(replay["receipt"])
        for key in ("event_id", "command_id", "canonical_id", "source_revision", "outcome"):
            require(receipt.get(key) == original.get(key), "immutable_replay_receipt_changed")
        changed = dict(payload, content="Changed immutable fixture payload")
        status, response = self.request(replay["path"], changed)
        require(status in {400, 409} and response.get("ok") is False
                and response.get("error") in {"idempotency_conflict", "source_event_conflict", "event_conflict"},
                "changed_immutable_payload_not_rejected")
        require({row["id"] for row in before} == {row["id"] for row in self.listed()},
                "conflict_partially_mutated_canonical_memory")
        require(not self.present(self.old), "old_replay_resurrected_withdrawn_value")
        return {"event_id": replay["event_id"], "duplicate_receipt": True, "conflict_rejected": True}

    def messages(self):
        contents = [
            ("user", "My durable deployment status color is amber. Fixture " + self.marker),
            ("assistant", "I guessed cobalt as your deployment status color."),
            ("user", "Correction: amber is correct. Cobalt was your mistake, not my preference."),
            ("user", "My durable deployment status color is amber. Fixture " + self.marker),
            ("assistant", "Acknowledged: amber is your deployment status color."),
            ("user", "Unrelated chat: the weather today is cloudy."),
        ]
        return [{"role": role, "content": content,
                 "message_uid": str(uuid.uuid5(uuid.NAMESPACE_URL, self.session("a") + ":" + str(index)))}
                for index, (role, content) in enumerate(contents)]

    def capture(self):
        provider, messages = self.providers["a"], self.messages()
        provider.sync_turn(messages[0]["content"], messages[1]["content"],
                           session_id=self.session("a"), messages=messages)
        before = json.dumps(messages, sort_keys=True)
        checkpoint = provider.on_pre_compress(messages, require_checkpoint=True)
        require(before == json.dumps(messages, sort_keys=True), "checkpoint_changed_messages")
        require("Evidence event references:" in checkpoint, "checkpoint_references_missing")
        provider.on_session_end(messages)
        self.settle()
        journal = provider._journal
        with journal.lock:
            event_ids = [row[0] for row in journal.db.execute(
                "SELECT event_id FROM delivery WHERE path LIKE '/capture/%' ORDER BY queue_sequence")]
        status, response = self.request("/capture/v1/status", {"event_ids": event_ids})
        require(status == 200 and response.get("ok") is True
                and all(row.get("status") == "canonical_committed"
                        for row in response.get("result", {}).get("items", []))
                and len(response["result"]["items"]) == len(event_ids), "capture_ack_not_canonical")
        return {"session_id": self.session("a"), "event_ids": event_ids,
                "message_uids": [row["message_uid"] for row in messages], "direct_messages": len(messages)}

    def context(self):
        provider = self.providers["a"]
        query = "deployment status color " + self.marker
        # Queue/fetch through the public asynchronous API; wait for a newly populated cache.
        provider.queue_prefetch(query, session_id=self.session("a"))
        deadline = time.monotonic() + self.timeout
        text = ""
        while time.monotonic() < deadline:
            text = provider.prefetch(query, session_id=self.session("a"))
            if text:
                break
            time.sleep(0.1)
        require("amber" in text.lower(), "corrected_context_missing")
        require("cobalt" not in text.lower(), "old_or_assistant_mistake_in_context")
        require("cloudy" not in text.lower(), "unrelated_chat_in_context")
        require(len(text.encode()) <= self.budget, "final_context_budget_exceeded")
        for line in text.splitlines():
            require(line.startswith("- [candidate inference;") or line.startswith("- [established fact;"),
                    "context_trust_label_missing")
        unrelated = "xylophonic quasar zeppelins"
        provider.queue_prefetch(unrelated, session_id=self.session("a"))
        # Wait for the actual fetch, including the valid empty-result cache entry.
        key = (self.session("a"), unrelated, provider._generation)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            with provider._state_lock:
                cached = provider._cache.get(key)
            if cached is not None:
                require(cached[1] == "", "unrelated_query_received_context")
                break
            time.sleep(0.1)
        else:
            raise CheckFailure("unrelated_context_fetch_unverified")
        return {"rendered_bytes": len(text.encode()), "budget": self.budget,
                "old_value_suppressed": True, "unrelated_empty": True, "trust_labels": True}

    def outage_pending(self):
        self.native("a", self.outage, "add")
        provider = self.providers["a"]
        provider.on_pre_compress(self.messages(), require_checkpoint=True)
        time.sleep(0.3)
        status = provider.delivery_status()
        require(status["local_pending"] + status["host_accepted"] > 0, "outage_not_observed")
        self.snapshot()
        return {"pending": status["local_pending"] + status["host_accepted"]}

    def snapshot(self):
        saved = {}
        for label, provider in self.providers.items():
            with provider._journal.lock:
                saved[label] = dict(provider._journal.db.execute("SELECT event_id,digest FROM delivery"))
        self.state["restart_snapshot"] = saved
        self.save()
        return {"immutable_deliveries": sum(len(rows) for rows in saved.values())}

    def verify_restart(self):
        for label, expected in self.state["restart_snapshot"].items():
            provider = self.providers[label]
            with provider._journal.lock:
                actual = dict(provider._journal.db.execute("SELECT event_id,digest FROM delivery"))
            require(all(actual.get(key) == value for key, value in expected.items()),
                    "restart_changed_or_lost_immutable_delivery")
        self.settle()
        return {"immutable_deliveries_preserved": True, "identities": self.state["identities"]}

    def forget(self):
        provider = self.providers["a"]
        result = json.loads(provider.handle_tool_call("memory_forget", {"id": self.state["current_id"]}))
        require(result.get("success") is not False and not result.get("error"), "global_forget_failed")
        for item in self.providers.values():
            item.reconcile_sources(dry_run=False)
        self.settle()
        require(not self.present(self.current), "reconciliation_undid_global_forget")
        query = "deployment status color " + self.marker
        provider.queue_prefetch(query, session_id=self.session("a"))
        deadline = time.monotonic() + self.timeout
        key = (self.session("a"), query, provider._generation)
        while time.monotonic() < deadline:
            with provider._state_lock:
                cached = provider._cache.get(key)
            if cached is not None:
                require(self.state["current_id"] not in cached[1], "forgotten_record_in_context")
                break
            time.sleep(0.1)
        else:
            raise CheckFailure("forget_context_fetch_unverified")
        return {"canonical_id": self.state["current_id"], "reconciliation_suppressed": True}

    def shutdown(self):
        for provider in self.providers.values():
            provider.shutdown()
            require(not provider.delivery_status()["worker_alive"], "provider_worker_shutdown_incomplete")
        self.providers.clear()
        return {"workers_stopped": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--timeout", default=45, type=float)
    args = parser.parse_args()
    scenario = Scenario(args.home.resolve(), args.base_url, args.marker, args.timeout)
    operations = {name: getattr(scenario, name) for name in (
        "boot", "settle", "native_add", "native_replace", "native_withdraw", "native_correct",
        "immutable_replay", "capture", "context", "outage_pending", "snapshot", "verify_restart",
        "forget", "shutdown")}
    try:
        for line in sys.stdin:
            operation = "invalid"
            try:
                request = json.loads(line)
                operation = request["op"]
                require(operation in operations, "unsupported_fixture_operation")
                result = operations[operation]()
                reply = {"kind": "reply", "op": operation, "ok": True, "result": result}
            except CheckFailure as error:
                reply = {"kind": "reply", "op": operation, "ok": False, "code": str(error)}
            except Exception as error:
                # Never print exception text, raw HTTP responses, tracebacks or memory bodies.
                reply = {"kind": "reply", "op": operation, "ok": False,
                         "code": "python_exception:" + type(error).__name__}
            print(json.dumps(reply, separators=(",", ":")), flush=True)
            if operation == "shutdown":
                break
    finally:
        scenario.shutdown()


if __name__ == "__main__":
    # Child does not need upstream or host credentials, even when inherited accidentally.
    os.environ.pop("OPENROUTER_API_KEY", None)
    main()
