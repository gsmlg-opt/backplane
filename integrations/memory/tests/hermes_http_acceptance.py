"""Manual Hermes acceptance peer; invoked only by test/hermes_memory_live_acceptance.exs.

The JSON-lines protocol carries synthetic fixture identities and safe results only.
Use the real Hermes interpreter: missing public APIs are an environment blocker.
No gateway token or upstream API key is accepted by this process.
"""

import argparse
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import sqlite3
import sys
import threading
import time
from types import SimpleNamespace
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class CheckFailure(Exception):
    def __init__(self, code, details=None):
        super().__init__(code)
        self.details = details or {}


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
        self.http_trace = []
        self.trace_lock = threading.Lock()

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
        runtime = {"python_version": ".".join(map(str, sys.version_info[:3])), "source_sha256": {}}
        for label, surface in (("MemoryProvider", MemoryProvider),
                               ("redact_for_egress", redact_for_egress)):
            path = inspect.getsourcefile(surface)
            require(path and Path(path).is_file(), "BLOCKED_ENV:hermes_runtime_source_unavailable")
            runtime["source_sha256"][label] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        name = "backplane_live_" + uuid.uuid4().hex
        source = Path(__file__).resolve().parents[1] / "hermes" / "__init__.py"
        spec = importlib.util.spec_from_file_location(name, source)
        self.plugin = importlib.util.module_from_spec(spec)
        sys.modules[name] = self.plugin
        spec.loader.exec_module(self.plugin)
        require(issubclass(self.plugin.BackplaneMemoryProvider, MemoryProvider), "hermes_contract_fallback")
        # Observe the real fixture-loaded transport without changing requests,
        # results, retry policy or installed provider/runtime files.
        transport = self.plugin._http

        def observed_http(base, path, args=None):
            started = time.monotonic()
            method = path.rsplit("/", 1)[-1]
            sample = {"method": method if method in {
                "recall", "list", "get", "forget", "source_capabilities", "source_status",
                "source_mutate", "source_reconcile", "message", "status", "session-start",
                "session-end", "pre-compress"} else "other"}
            if method == "recall":
                sample["query_kind"] = "unrelated" if (args or {}).get("query") == "xylophonic quasar zeppelins" else "fixture"
            try:
                response = transport(base, path, args)
                sample.update(self.response_metadata(response.get("http_status"), response))
                return response
            except Exception as error:
                sample["exception_type"] = type(error).__name__
                raise
            finally:
                sample["elapsed_ms"] = round((time.monotonic() - started) * 1000)
                with self.trace_lock:
                    self.http_trace.append(sample)
                    del self.http_trace[:-48]

        self.plugin._http = observed_http
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
        return {"identities": identities, "sessions": [self.session(x) for x in ("a", "b")],
                "runtime": runtime}

    def session(self, label):
        return "hermes-live-" + self.marker + "-" + label

    def settle(self):
        results = {}
        for label, provider in self.providers.items():
            result = provider.flush(timeout=self.timeout, canonical=True)
            if not result["success"]:
                raise CheckFailure("canonical_delivery_unsettled:" + label,
                                   self.delivery_diagnostics())
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

    def request(self, path, payload, timeout=10):
        request = Request(self.base + path, json.dumps(payload).encode(),
                          {"Content-Type": "application/json"}, method="POST")
        try:
            with urlopen(request, timeout=timeout) as response:
                return response.status, json.loads(response.read(2 * 1024 * 1024))
        except HTTPError as error:
            return error.code, json.loads(error.read(2 * 1024 * 1024))
        except (URLError, TimeoutError):
            raise CheckFailure("host_transport_unavailable") from None

    def safe_code(self, value):
        allowed = self.plugin.ERROR_CODES | {
            "request_rejected", "retry_exhausted", "request_failed", "http_error", "invalid_response",
            "transport_failure", "delivery_exhausted", "authority_changed", "partition_mismatch",
            "invalid_protocol", "capture_binding_mismatch", "unsupported_capability", "not_negotiated",
            "storage_unavailable", "invalid_ack", "revision_conflict", "snapshot_conflict",
            # Fixed public stage codes from Memory.Recall.Pipeline.stage_error/1.
            "query_plan_failed", "retrieval_failed", "post_fusion_failed", "reranker_failed",
            "packing_failed", "provenance_failed", "trace_create_failed", "trace_finalize_failed",
            "pipeline_failed", "recall_already_failed",
        }
        return value if value is None or isinstance(value, str) and value in allowed else "unclassified_error"

    def response_metadata(self, status, response):
        result = response.get("result") if isinstance(response, dict) else None
        data = {"http_status": status, "ok": response.get("ok") is True,
                "error": self.safe_code(response.get("error"))}
        if isinstance(result, dict):
            for key, allowed in {
                "status": {"pending", "committed", "rejected", "host_accepted", "canonical_committed"},
                "outcome": {"applied", "unchanged", "stale", "suppressed", "withdrawn"},
                "authority": {"provisional", "canonical"},
                "consistency": {"pending_canonical_ack", "canonical"},
                "phase": {"begin", "page", "commit"},
                "reconciliation_status": {"pending", "committed", "superseded", "aborted"},
            }.items():
                if key in result:
                    data[key] = result[key] if result[key] in allowed else "unclassified_status"
            if "error_code" in result:
                data["error_code"] = self.safe_code(result["error_code"])
            for key in ("source_revision", "revision"):
                if isinstance(result.get(key), int):
                    data[key] = result[key]
            rows = result.get("results")
            if isinstance(rows, list):
                data.update(result_count=len(rows),
                            relevance_accepted_count=sum(row.get("relevance_accepted") is True
                                                         for row in rows if isinstance(row, dict)))
            for key in ("ready", "capture_ready", "supported", "success", "stale"):
                if isinstance(result.get(key), bool):
                    data[key] = result[key]
            if "capture_error" in result:
                data["capture_error"] = self.safe_code(result["capture_error"])
        return data

    def diagnostic_request(self, path, payload):
        try:
            status, response = self.request(path, payload, timeout=3)
            return self.response_metadata(status, response)
        except Exception as error:
            return {"diagnostic_unavailable": True, "exception_type": type(error).__name__}

    def delivery_diagnostics(self):
        diagnostics = {"source_capabilities": self.diagnostic_request(
            "/memory/hermes/call/source_capabilities", {})}
        with self.trace_lock:
            diagnostics["actual_transport_observations"] = list(self.http_trace)
        for label, provider in self.providers.items():
            status = provider.delivery_status()
            local = {key: status[key] for key in (
                "local_pending", "host_accepted", "canonical_committed", "rejected",
                "capture_deferred", "pending_reconciliation", "worker_alive")}
            for key, allowed in {
                "peer": {"ready", "unverified", "rejected", "not_negotiated", "unavailable"},
                "binding": {"verified", "unverified"},
                "capture_binding": {"verified", "unverified", "capture_unavailable", "capture_binding_mismatch"},
            }.items():
                value = status.get(key)
                local[key] = value if value in allowed else "unclassified_status"
            local["error_codes"] = [self.safe_code(code) for code in status["error_codes"]]
            with provider._journal.lock:
                rows = [dict(row) for row in provider._journal.db.execute(
                    "SELECT event_id,path,payload,state,attempts,error_code FROM delivery "
                    "WHERE state!='canonical_committed' ORDER BY queue_sequence LIMIT 8")]
            samples = []
            for row in rows:
                sample = {key: row[key] for key in ("event_id", "state", "attempts")}
                sample["error_code"] = self.safe_code(row["error_code"])
                payload = json.loads(row["payload"])
                if row["path"].startswith("/capture/"):
                    sample["kind"] = "capture"
                    try:
                        http_status, reply = self.request("/capture/v1/status", {"event_ids": [row["event_id"]]}, timeout=3)
                        sample["host"] = self.response_metadata(http_status, reply)
                        items = reply.get("result", {}).get("items", [])
                        sample["capture_statuses"] = [
                            {"status": item.get("status") if item.get("status") in {
                                "host_accepted", "canonical_committed", "rejected", "unknown"}
                             else "unclassified_status", "error_code": self.safe_code(item.get("error_code"))}
                            for item in items if isinstance(item, dict)]
                    except Exception as error:
                        sample["host"] = {"diagnostic_unavailable": True, "exception_type": type(error).__name__}
                else:
                    sample["kind"] = "source"
                    sample["host"] = self.diagnostic_request("/memory/hermes/call/source_status", {
                        "source": payload["source"], "event_id": row["event_id"], **provider._selector()})
                samples.append(sample)
            diagnostics[label] = {"local": local, "noncanonical_samples": samples}
        return diagnostics

    def context_diagnostics(self, query, requested_generation):
        provider = self.providers["a"]
        with provider._state_lock:
            matching = [(key, value) for key, value in provider._cache.items()
                        if key[:2] == (self.session("a"), query)]
            cache = [{"generation": key[2], "empty": value[1] == "",
                      "unexpired": value[0] > time.monotonic()}
                     for key, value in matching]
            generation = provider._generation
            queued = [key[2] for key in provider._prefetch_jobs if key[:2] == (self.session("a"), query)]
        return {"requested_generation": requested_generation, "current_generation": generation,
                "matching_cache": cache, "queued_generations": queued,
                "direct_recall": self.diagnostic_request("/memory/hermes/call/recall", {
                    "query": query, "limit": 5, "token_budget": self.budget}),
                "delivery": self.delivery_diagnostics()}

    def diagnostic_delivery(self):
        return self.delivery_diagnostics()

    def wait_current_context(self, query, failure_code):
        provider = self.providers["a"]
        session = self.session("a")
        with provider._journal.lock, provider._state_lock:
            initial_generation = provider._generation
            initial_cache = provider._cache.get((session, query, initial_generation))
            binding = provider._journal.get("binding_fingerprint")
        queued_generation = None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            # Follow the provider's actual invalidation generation. Hold both
            # owning locks while observing freshness and identity so a source
            # settlement cannot invalidate the selected cache mid-observation.
            with provider._journal.lock, provider._state_lock:
                generation = provider._generation
                current_binding = provider._journal.get("binding_fingerprint")
                session_changed = provider._session_id != session
                binding_changed = binding is not None and current_binding != binding
                if binding is None and current_binding:
                    binding = current_binding
                key = (session, query, generation)
                cached = provider._cache.get(key)
                ready = (provider._peer or {}).get("state") == "ready"
                complete = (cached is not None and cached is not initial_cache
                            and cached[0] > time.monotonic() and key not in provider._prefetch_jobs
                            and ready and bool(current_binding)
                            and not provider._journal.get("binding_blocked"))
                if complete and not session_changed and not binding_changed:
                    text = provider.prefetch(query, session_id=session)
                    if (text == cached[1] and cached[0] > time.monotonic()
                            and key not in provider._prefetch_jobs):
                        return text, generation
            if session_changed or binding_changed:
                code = "context_session_changed" if session_changed else "context_binding_changed"
                raise CheckFailure(code, self.context_diagnostics(query, initial_generation))
            if queued_generation != generation:
                # An invalidation clears queued work too. Requeue through the
                # public API without treating its immediate empty return as a
                # completed fetch or retaining a stale generation's result.
                provider.queue_prefetch(query, session_id=session)
                queued_generation = generation
            time.sleep(0.1)
        raise CheckFailure(failure_code, self.context_diagnostics(query, initial_generation))

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

    def required_checkpoint_failure(self):
        # Exercise the real host caller and manager, not just the plugin hook.
        # The context-engine sentinel stops at dispatch: this proves retry can
        # resume after persistence recovers, not that a summary was generated.
        try:
            from agent.conversation_compression import compress_context
            from agent.conversation_compression_checkpoint import CompressionCheckpointUnavailable
            from agent.memory_manager import MemoryManager
        except ImportError:
            raise CheckFailure("BLOCKED_ENV:hermes_required_checkpoint_caller_unavailable") from None

        class DispatchObserved(Exception):
            pass

        class SentinelCompressor:
            def __init__(self):
                self.calls = 0
                self.checkpoint_context = ""

            def compress(self, messages, *, memory_context="", **kwargs):
                self.calls += 1
                self.checkpoint_context = memory_context
                raise DispatchObserved()

        provider = self.providers["a"]
        manager = MemoryManager()
        manager.add_provider(provider)
        require(manager.supports_pre_compress_checkpoint(2), "required_checkpoint_capability_missing")
        compressor = SentinelCompressor()
        agent = SimpleNamespace(
            context_compressor=compressor, _memory_manager=manager, _session_db=None,
            session_id=self.session("a"), model="owned-dispatch-sentinel", api_mode="chat_completions",
            compression_checkpoint_required=True, compression_in_place=True,
            _compression_feasibility_checked=True, _emit_status=lambda _message: None,
        )
        messages = self.messages()
        before = json.dumps(messages, sort_keys=True)
        journal = provider._journal
        source_hashes = {}
        for label, surface in (("compress_context", compress_context), ("MemoryManager", MemoryManager)):
            path = inspect.getsourcefile(surface)
            require(path and Path(path).is_file(), "BLOCKED_ENV:hermes_runtime_source_unavailable")
            source_hashes[label] = hashlib.sha256(Path(path).read_bytes()).hexdigest()

        with journal.lock:
            # query_only applies only to our owning connection. The lock fences
            # its delivery worker until the PRAGMA is restored in all outcomes.
            require(journal.db.execute("PRAGMA query_only").fetchone()[0] == 0,
                    "owned_journal_already_readonly")
            deliveries_before = list(journal.db.execute("SELECT event_id,digest FROM delivery ORDER BY queue_sequence"))
            messages_before = list(journal.db.execute("SELECT * FROM messages ORDER BY identity"))
            journal.db.execute("PRAGMA query_only=ON")
            try:
                try:
                    compress_context(agent, messages, "Owned synthetic system prompt", force=True)
                except CompressionCheckpointUnavailable as error:
                    cause = error.__cause__
                    require(isinstance(cause, sqlite3.OperationalError)
                            and getattr(cause, "sqlite_errorcode", -1) & 255 == sqlite3.SQLITE_READONLY,
                            "required_checkpoint_not_blocked_by_owned_persistence_failure")
                else:
                    raise CheckFailure("required_checkpoint_failure_did_not_block_compression")
                require(compressor.calls == 0, "compression_dispatched_after_checkpoint_failure")
                require(json.dumps(messages, sort_keys=True) == before, "failed_checkpoint_changed_messages")
                require(deliveries_before == list(journal.db.execute(
                    "SELECT event_id,digest FROM delivery ORDER BY queue_sequence"))
                    and messages_before == list(journal.db.execute("SELECT * FROM messages ORDER BY identity")),
                    "failed_checkpoint_partially_changed_journal")
                require(not journal.db.in_transaction, "failed_checkpoint_left_transaction_open")
            finally:
                journal.db.execute("PRAGMA query_only=OFF")
            require(journal.db.execute("PRAGMA query_only").fetchone()[0] == 0,
                    "owned_journal_readonly_not_restored")

            try:
                compress_context(agent, messages, "Owned synthetic system prompt", force=True)
            except DispatchObserved:
                pass
            else:
                raise CheckFailure("recovered_checkpoint_retry_did_not_reach_compressor")
            require(compressor.calls == 1, "recovered_checkpoint_retry_dispatch_count")
            require(json.dumps(messages, sort_keys=True) == before, "checkpoint_retry_changed_messages")
            require("Evidence event references:" in compressor.checkpoint_context,
                    "retry_checkpoint_references_missing")
            for message in messages:
                identity = self.session("a") + ":native:" + message["message_uid"]
                row = journal.db.execute("SELECT event_id FROM messages WHERE identity=?", (identity,)).fetchone()
                require(row is not None and row[0] in compressor.checkpoint_context
                        and journal.db.execute("SELECT 1 FROM delivery WHERE event_id=?", (row[0],)).fetchone(),
                        "retry_checkpoint_reference_not_durable")

        return {"evidence": "real_hermes_required_checkpoint_caller_owned_sqlite_failure_sentinel_dispatch",
                "persistence_failure": "SQLITE_READONLY", "blocked_before_compressor": True,
                "messages_unchanged": True, "partial_journal_write": False,
                "retry_dispatched": True, "durable_direct_event_references": len(messages),
                "full_compression_verified": False, "runtime_source_sha256": source_hashes}

    def context(self):
        query = "deployment status color " + self.marker
        text, generation = self.wait_current_context(query, "corrected_context_missing")
        if "amber" not in text.lower():
            raise CheckFailure("corrected_context_missing", self.context_diagnostics(query, generation))
        require("cobalt" not in text.lower(), "old_or_assistant_mistake_in_context")
        require("cloudy" not in text.lower(), "unrelated_chat_in_context")
        require(len(text.encode()) <= self.budget, "final_context_budget_exceeded")
        status, recalled = self.request("/memory/hermes/call/recall", {
            "query": query, "limit": 5, "token_budget": self.budget,
        })
        require(status == 200 and recalled.get("ok") is True, "context_readback_failed")
        whole_contents = {row["content"].strip()
                          for row in recalled.get("result", {}).get("results", [])
                          if isinstance(row, dict) and isinstance(row.get("content"), str)}
        for line in text.splitlines():
            require(line.startswith("- [candidate inference;") or line.startswith("- [established fact;"),
                    "context_trust_label_missing")
            require("] " in line and line.split("] ", 1)[1] in whole_contents,
                    "context_entry_was_sliced_or_unverifiable")
        unrelated = "xylophonic quasar zeppelins"
        unrelated_text, _generation = self.wait_current_context(unrelated, "unrelated_context_fetch_unverified")
        require(unrelated_text == "", "unrelated_query_received_context")
        return {"rendered_bytes": len(text.encode()), "budget": self.budget,
                "old_value_suppressed": True, "unrelated_empty": True,
                "trust_labels": True, "whole_entries": True}

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
        text, _generation = self.wait_current_context(query, "forget_context_fetch_unverified")
        require(self.state["current_id"] not in text, "forgotten_record_in_context")
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
        "immutable_replay", "capture", "required_checkpoint_failure", "diagnostic_delivery", "context", "outage_pending", "snapshot", "verify_restart",
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
                reply = {"kind": "reply", "op": operation, "ok": False, "code": str(error),
                         "diagnostics": error.details}
            except Exception as error:
                # Never print exception text, raw HTTP responses, tracebacks or memory bodies.
                reply = {"kind": "reply", "op": operation, "ok": False,
                         "code": "python_exception:" + type(error).__name__}
            print(json.dumps(reply, separators=(",", ":")), flush=True)
            if operation == "shutdown":
                break
    finally:
        try:
            scenario.shutdown()
        except Exception:
            print(json.dumps({"kind": "cleanup", "ok": False,
                              "code": "provider_worker_shutdown_incomplete"}), flush=True)
            return 1
    return 0


if __name__ == "__main__":
    # Child does not need upstream or host credentials, even when inherited accidentally.
    os.environ.pop("OPENROUTER_API_KEY", None)
    sys.exit(main())
