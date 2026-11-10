import copy
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse

PLUGIN_DIR = Path(__file__).parents[1] / "hermes"
SHARED_INSTRUCTIONS = Path(__file__).parents[1] / "shared" / "INSTRUCTIONS.md"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=[str(path.parent)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


plugin = load(PLUGIN_DIR / "__init__.py", "backplane_memory")


class Response:
    def __init__(self, body, status=200):
        self.body, self.status = body, status
    def __enter__(self): return self
    def __exit__(self, *_args): return False
    def read(self, *args): return json.dumps(self.body).encode()


def http_error(status, body, reason="private-reason"):
    return HTTPError("url", status, reason, {}, io.BytesIO(json.dumps(body).encode()))


class Recorder:
    """Fake urlopen recording each request; ``responses`` maps a path suffix to a reply."""

    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def __call__(self, request, timeout):
        path = urlparse(request.full_url).path
        self.calls.append({"url": request.full_url, "path": path, "method": request.method,
                           "body": json.loads(request.data.decode()), "timeout": timeout})
        for suffix, reply in self.responses.items():
            if path.endswith(suffix):
                if isinstance(reply, BaseException):
                    raise reply
                return reply(path, self.calls[-1]["body"]) if callable(reply) else Response(reply)
        raise AssertionError("unexpected request " + path)


def record(**provenance):
    base = {"id": "mem-1", "kind": "fact", "title": None, "content": "repo backplane lives in ~/Workspace",
            "status": "active", "observed_at": "2026-11-09T10:00:00Z",
            "provenance": {"writer": "agent", "host": "gao-mbp", "agent": "codex", "integration": "codex",
                           "session": "s-9"}}
    base.update(provenance)
    return base


class HermesProviderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.provider = self.new_provider()

    def new_provider(self, session="session-1", **kwargs):
        provider = plugin.BackplaneMemoryProvider()
        with patch.object(plugin.BackplaneMemoryProvider, "_start_worker", lambda s: None), \
             patch.dict(plugin.os.environ, {"BACKPLANE_MEMORY_URL": "http://127.0.0.1:4222", "BACKPLANE_MEMORY_AGENT_ID": "hermes test"}):
            provider.initialize(session, hermes_home=str(self.home), cwd="/Users/gao/.dotfiles", **kwargs)
        self.addCleanup(provider.shutdown)
        return provider

    def rows(self, suffix):
        return [json.loads(r["payload"]) for r in self.provider._journal.pending(limit=100) if r["path"].endswith(suffix)]

    def tool(self, name, args, responses):
        recorder = Recorder(responses)
        with patch.object(plugin, "urlopen", side_effect=recorder):
            result = json.loads(self.provider.handle_tool_call(name, args))
        return result, recorder.calls

    # -- static surface -----------------------------------------------------

    def test_availability_and_system_prompt_are_local_and_equal_to_shared_instructions(self):
        with patch.object(plugin, "urlopen", side_effect=AssertionError("network forbidden")):
            self.assertTrue(self.provider.is_available())
            prompt = self.provider.system_prompt_block()
        self.assertEqual(prompt, SHARED_INSTRUCTIONS.read_text(encoding="utf-8"))
        self.assertIn("memory::remember", prompt)

    def test_installed_layout_reads_the_bundled_instructions_copy(self):
        installed = self.home / "plugins" / "backplane-memory"
        shutil.copytree(PLUGIN_DIR, installed, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copy(SHARED_INSTRUCTIONS, installed / "INSTRUCTIONS.md")
        (installed / "INSTRUCTIONS.md").write_text("bundled copy\n", encoding="utf-8")
        module = load(installed / "__init__.py", "backplane_memory_installed")
        self.assertEqual(module.BackplaneMemoryProvider().system_prompt_block(), "bundled copy\n")

    def test_tool_schemas_expose_the_five_memory_tools(self):
        schemas = {schema["name"]: schema for schema in self.provider.get_tool_schemas()}
        self.assertEqual(sorted(schemas), ["memory_forget", "memory_get", "memory_recent", "memory_remember", "memory_search"])
        self.assertEqual(schemas["memory_search"]["parameters"]["required"], ["query"])
        self.assertEqual(schemas["memory_remember"]["parameters"]["required"], ["content"])
        self.assertEqual(schemas["memory_forget"]["parameters"]["required"], ["id", "reason"])
        self.assertEqual(schemas["memory_get"]["parameters"]["required"], ["id"])
        self.assertEqual(schemas["memory_remember"]["parameters"]["properties"]["kind"]["enum"], ["fact", "procedure", "worklog", "note"])

    def test_no_retired_protocol_vocabulary_remains_in_the_plugin(self):
        forbidden = re.compile(r"memory_access_id|partition|source_capabilities|recall", re.IGNORECASE)
        files = sorted(PLUGIN_DIR.glob("*.py")) + [PLUGIN_DIR / "plugin.yaml"]
        offenders = [f"{path.name}:{number}" for path in files
                     for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1) if forbidden.search(line)]
        self.assertEqual(offenders, [])
        for retired in ("source.py", "source_contract.py", "rollout.py", "context_merge.py"):
            self.assertFalse((PLUGIN_DIR / retired).exists(), retired)

    # -- prefetch -----------------------------------------------------------

    def test_prefetch_searches_the_turn_text_and_renders_provenance(self):
        recorder = Recorder({"/call/search": {"ok": True, "result": {"results": [record(), record(id="mem-2", kind="procedure", content="restart with launchctl", status="superseded")]}}})
        with patch.object(plugin, "urlopen", side_effect=recorder):
            text = self.provider.prefetch("where is the backplane repo?")
        [call] = recorder.calls
        self.assertEqual(call["url"], "http://127.0.0.1:4222/memory/hermes%20test/call/search")
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["body"], {"query": "where is the backplane repo?", "limit": 8})
        self.assertLessEqual(call["timeout"], 8)
        for fragment in ("repo backplane lives in ~/Workspace", "fact", "host gao-mbp", "agent codex", "observed 2026-11-09T10:00:00Z", "mem-1"):
            self.assertIn(fragment, text)
        self.assertNotIn("launchctl", text)

    def test_prefetch_uses_the_cache_and_invalidates_after_a_write(self):
        recorder = Recorder({"/call/search": {"ok": True, "result": {"results": [record()]}},
                             "/call/remember": {"ok": True, "result": record(id="mem-3")}})
        with patch.object(plugin, "urlopen", side_effect=recorder):
            first = self.provider.prefetch("backplane")
            self.assertEqual(self.provider.prefetch("backplane"), first)
            self.assertEqual(len(recorder.calls), 1)
            self.provider.handle_tool_call("memory_remember", {"content": "new fact"})
            self.provider.prefetch("backplane")
        self.assertEqual([call["path"].rsplit("/", 1)[1] for call in recorder.calls], ["search", "remember", "search"])

    def test_queue_prefetch_warms_the_cache_in_the_background(self):
        self.provider.queue_prefetch("backplane")
        job = self.provider._prefetch_jobs.popitem(last=False)[0]
        recorder = Recorder({"/call/search": {"ok": True, "result": {"results": [record()]}}})
        with patch.object(plugin, "urlopen", side_effect=recorder):
            self.provider._fetch_context(job)
        self.assertEqual(recorder.calls[0]["body"], {"query": "backplane", "limit": 8})
        with patch.object(plugin, "urlopen", side_effect=AssertionError("cached")):
            self.assertIn("mem-1", self.provider.prefetch("backplane"))

    def test_offline_results_are_marked_as_local_only(self):
        body = {"ok": True, "result": {"results": [record()], "offline": True, "source": "local"}}
        with patch.object(plugin, "urlopen", side_effect=Recorder({"/call/search": body})):
            self.assertIn("offline", self.provider.prefetch("backplane").lower())

    def test_rendered_context_respects_the_whole_entry_budget(self):
        self.provider._config["context_token_budget"] = 400
        rows = [record(id="big", content="x" * 1000), record(id="small", content="small fact")]
        with patch.object(plugin, "urlopen", side_effect=Recorder({"/call/search": {"ok": True, "result": {"results": rows}}})):
            text = self.provider.prefetch("anything")
        self.assertIn("small fact", text)
        self.assertNotIn("xxx", text)
        self.assertLessEqual(len(text.encode()), 400)

    def test_gateway_unavailable_degrades_to_no_context_with_one_warning(self):
        for failure in (http_error(503, {"ok": False, "error": "gateway_unavailable"}),
                        http_error(504, {"ok": False, "error": "gateway_timeout"}),
                        http_error(404, {"ok": False, "error": "unknown method: search"}),
                        http_error(500, {"ok": False, "error": "local_store_error"}),
                        URLError("connection refused private-secret"), TimeoutError()):
            with self.subTest(failure=failure):
                provider = self.new_provider(session="s-" + type(failure).__name__ + str(getattr(failure, "code", "")))
                with patch.object(plugin, "urlopen", side_effect=failure), \
                     self.assertLogs(plugin.logger, level="WARNING") as logs:
                    self.assertEqual(provider.prefetch("backplane"), "")
                self.assertEqual(len(logs.records), 1)
                self.assertNotIn("private", "\n".join(logs.output))

    def test_malformed_search_bodies_yield_no_context(self):
        for body in ({"ok": True, "result": "text"}, {"ok": True, "result": {"results": "x"}}, [], {"ok": False}):
            with self.subTest(body=body), patch.object(plugin, "urlopen", return_value=Response(body)), \
                 patch.object(plugin.logger, "warning"):
                self.assertEqual(self.provider.prefetch("q-" + json.dumps(body)), "")

    def test_prefetch_never_raises_even_after_shutdown(self):
        with patch.object(plugin, "urlopen", side_effect=RuntimeError("boom")), \
             self.assertLogs(plugin.logger, level="WARNING"):
            self.assertEqual(self.provider.prefetch("backplane"), "")
        self.provider.shutdown()
        self.assertEqual(self.provider.prefetch("backplane"), "")
        self.provider.queue_prefetch("backplane")

    # -- tools --------------------------------------------------------------

    def test_search_tool_passes_filters_and_returns_the_host_result(self):
        result, [call] = self.tool("memory_search", {"query": "repo", "host": "gao-mbp", "kind": "fact", "limit": 3, "bogus": 1},
                                   {"/call/search": {"ok": True, "result": {"results": [record()]}}})
        self.assertEqual(call["body"], {"query": "repo", "host": "gao-mbp", "kind": "fact", "limit": 3})
        self.assertEqual(result, {"results": [record()]})

    def test_remember_tool_carries_the_current_session_id(self):
        result, [call] = self.tool("memory_remember", {"content": "fact", "kind": "fact", "subjects": [{"type": "repo", "key": "backplane"}], "tags": ["t"]},
                                   {"/call/remember": {"ok": True, "result": record(id="mem-7")}})
        self.assertEqual(call["url"], "http://127.0.0.1:4222/memory/hermes%20test/call/remember")
        self.assertEqual(call["body"], {"content": "fact", "kind": "fact", "subjects": [{"type": "repo", "key": "backplane"}], "tags": ["t"], "session_id": "session-1"})
        self.assertEqual(result["id"], "mem-7")
        self.provider.on_session_switch("session-2", parent_session_id="session-1", reset=True)
        _result, [call] = self.tool("memory_remember", {"content": "later"}, {"/call/remember": {"ok": True, "result": record()}})
        self.assertEqual(call["body"]["session_id"], "session-2")

    def test_get_recent_and_forget_tools_map_to_their_methods(self):
        responses = {suffix: {"ok": True, "result": {"done": suffix}} for suffix in ("/call/get", "/call/recent", "/call/forget")}
        _r, [get] = self.tool("memory_get", {"id": "mem-1"}, responses)
        _r, [recent] = self.tool("memory_recent", {"agent": "codex", "limit": 5}, responses)
        _r, [forget] = self.tool("memory_forget", {"id": "mem-1", "reason": "moved"}, responses)
        self.assertEqual((get["path"], get["body"]), ("/memory/hermes%20test/call/get", {"id": "mem-1"}))
        self.assertEqual((recent["path"], recent["body"]), ("/memory/hermes%20test/call/recent", {"agent": "codex", "limit": 5}))
        self.assertEqual((forget["path"], forget["body"]), ("/memory/hermes%20test/call/forget", {"id": "mem-1", "reason": "moved"}))

    def test_tool_failures_are_explicit_redacted_and_closed(self):
        for name, args in [("memory_search", {"query": "q"}), ("memory_remember", {"content": "c"}), ("memory_forget", {"id": "x", "reason": "r"}),
                           ("memory_get", {"id": "x"}), ("memory_recent", {})]:
            stream = io.BytesIO(b'{"ok":false,"error":"gateway_unavailable","detail":"private-credential"}')
            error = HTTPError("url", 503, "private-credential", {}, stream)
            with self.subTest(name=name), patch.object(plugin, "urlopen", side_effect=error), \
                 self.assertLogs(plugin.logger, level="WARNING") as logs:
                result = json.loads(self.provider.handle_tool_call(name, args))
            self.assertEqual(result, {"success": False, "error": "gateway_unavailable", "http_status": 503})
            self.assertNotIn("private-credential", json.dumps(result) + "\n".join(logs.output))
            self.assertTrue(stream.closed)

    def test_tool_argument_errors_do_not_reach_the_network(self):
        with patch.object(plugin, "urlopen", side_effect=AssertionError("network forbidden")):
            self.assertEqual(json.loads(self.provider.handle_tool_call("memory_unknown", {}))["error"], "unknown_tool")
            self.assertEqual(json.loads(self.provider.handle_tool_call("memory_search", {}))["error"], "invalid_arguments")
            self.assertEqual(json.loads(self.provider.handle_tool_call("memory_forget", {"id": "x"}))["error"], "invalid_arguments")

    def test_tool_calls_from_another_profile_are_refused(self):
        with patch.object(plugin, "urlopen", side_effect=AssertionError("network forbidden")):
            result = json.loads(self.provider.handle_tool_call("memory_search", {"query": "q"}, hermes_home=str(self.home / "other")))
        self.assertEqual(result, {"success": False, "error": "profile_binding_mismatch"})

    # -- on_memory_write ----------------------------------------------------

    def test_memory_write_queues_a_remember_note_and_delivers_it(self):
        self.provider.on_memory_write("add", "memory", "user prefers fish", metadata={"session_id": "native-session"})
        self.provider.on_memory_write("replace", "user", "user is Gao", metadata={"previous_content": "old"})
        self.provider.on_memory_write("remove", "memory", "", metadata={"previous_content": "user prefers fish"})
        rows = self.rows("/call/remember")
        self.assertEqual(len(rows), 2)
        first, second = rows
        self.assertEqual({key: first[key] for key in ("content", "kind", "writer", "session_id")},
                         {"content": "user prefers fish", "kind": "note", "writer": "agent", "session_id": "native-session"})
        self.assertEqual(second["session_id"], "session-1")
        self.assertTrue(first["request_key"].startswith("hermes:") and first["request_key"] != second["request_key"])
        recorder = Recorder({"/call/remember": lambda _path, body: Response({"ok": True, "result": record(id="r-" + body["content"])}),
                             "/capture/v1/hooks/hermes/session-start": lambda _path, body: Response({"ok": True, "status": "accepted", "event_id": body["event_id"]}, 202)})
        with patch.object(plugin, "urlopen", side_effect=recorder):
            self.provider._deliver_once()
        remembers = [call for call in recorder.calls if call["path"].endswith("/call/remember")]
        self.assertEqual([call["body"] for call in remembers], rows)
        self.assertEqual(self.rows("/call/remember"), [])
        self.assertEqual(self.provider.delivery_status()["canonical_committed"], 2)

    def test_memory_write_retries_on_gateway_unavailable_and_never_raises(self):
        self.provider.on_memory_write("add", "memory", "fact")
        recorder = Recorder({"/call/remember": http_error(503, {"ok": False, "error": "gateway_unavailable"}),
                             "/capture/v1/hooks/hermes/session-start": lambda _p, body: Response({"ok": True, "status": "accepted", "event_id": body["event_id"]}, 202)})
        with patch.object(plugin, "urlopen", side_effect=recorder), self.assertLogs(plugin.logger, level="WARNING"):
            self.provider._deliver_once()
        [row] = [row for row in self.provider._journal.pending(now=float("inf")) if row["path"].endswith("/call/remember")]
        self.assertEqual((row["state"], row["attempts"], row["error_code"]), ("local_pending", 1, "gateway_unavailable"))
        with patch.object(self.provider._journal, "enqueue", side_effect=RuntimeError("delivery_journal_full")), \
             self.assertLogs(plugin.logger, level="WARNING"):
            self.provider.on_memory_write("add", "memory", "another fact")

    def test_rejected_write_is_terminal_without_blocking_later_rows(self):
        self.provider.on_memory_write("add", "memory", "bad")
        self.provider.on_memory_write("add", "memory", "good")
        def reply(_path, body):
            if body["content"] == "bad":
                raise http_error(400, {"ok": False, "error": "invalid: kind is invalid"})
            return Response({"ok": True, "result": record()})
        recorder = Recorder({"/call/remember": reply,
                             "/capture/v1/hooks/hermes/session-start": lambda _p, body: Response({"ok": True, "status": "accepted", "event_id": body["event_id"]}, 202)})
        with patch.object(plugin, "urlopen", side_effect=recorder), self.assertLogs(plugin.logger, level="WARNING"):
            self.provider._deliver_once()
        status = self.provider.delivery_status()
        self.assertEqual((status["rejected"], status["canonical_committed"]), (1, 1))

    def test_nonprimary_context_skips_automatic_writes(self):
        provider = self.new_provider(agent_context="subagent")
        before = provider.delivery_status()["local_pending"]
        provider.sync_turn("user", "assistant", messages=[{"role": "user", "content": "user", "message_uid": "u1"}])
        provider.on_memory_write("add", "memory", "fact")
        self.assertEqual(provider.delivery_status()["local_pending"], before)

    # -- capture (unchanged contract) ---------------------------------------

    def test_capture_rows_carry_no_retired_or_reserved_fields(self):
        self.provider.sync_turn("hello", "hi", messages=[{"role": "user", "content": "hello", "message_uid": "u1"}])
        reserved = {"host_id", "client_id", "source_client_id", "memory_space_id", "scope", "namespace", "requesting_actor", "authority_version", "access_id"}
        for row in self.provider._journal.pending(limit=100):
            self.assertTrue(row["path"].startswith("/capture/v1/hooks/hermes/"))
            payload = json.loads(row["payload"])
            self.assertEqual(payload["protocol"], "hermes_capture.v1")
            self.assertFalse(reserved & set(payload), payload)

    def test_capture_delivery_needs_no_negotiation_and_settles_via_status(self):
        self.provider.sync_turn("hello", "hi", messages=[{"role": "user", "content": "hello", "message_uid": "u1"}])
        recorder = Recorder({"/capture/v1/status": lambda _p, body: Response({"ok": True, "result": {"protocol": "hermes_capture.v1", "items": [{"event_id": event, "status": "canonical_committed"} for event in body["event_ids"]]}}),
                             "": lambda _p, body: Response({"ok": True, "status": "accepted", "event_id": body["event_id"]}, 202)})
        with patch.object(plugin, "urlopen", side_effect=recorder):
            self.provider._deliver_once()
            self.assertEqual(self.provider.delivery_status()["local_pending"], 0)
            self.provider._journal.db.execute("UPDATE delivery SET next_at=0")
            self.provider._deliver_once()
        self.assertEqual(self.provider.delivery_status()["host_accepted"], 0)
        self.assertGreater(self.provider.delivery_status()["canonical_committed"], 0)
        self.assertTrue(all("/call/" not in call["path"] for call in recorder.calls))

    def test_message_occurrences_and_checkpoint_overlap_are_durable(self):
        messages = [{"role": "user", "content": "same", "message_uid": "u1"}, {"role": "assistant", "content": "a guess", "message_uid": "a1"}, {"role": "user", "content": "same", "message_uid": "u2"}]
        before = copy.deepcopy(messages)
        self.provider.sync_turn("same", "a guess", session_id="session-1", messages=messages)
        first = self.rows("message")
        self.assertEqual([r["message_uid"] for r in first], ["u1", "a1", "u2"])
        self.assertEqual([r["role"] for r in first], ["user", "assistant", "user"])
        reference = self.provider.on_pre_compress(messages, require_checkpoint=True)
        self.assertIsInstance(reference, str)
        self.assertEqual(messages, before)
        self.assertEqual(len(self.rows("message")), 3)

    def test_checkpoint_local_persistence_failure_raises(self):
        self.assertEqual(self.provider.pre_compress_checkpoint_api_version, 2)
        with patch.object(self.provider._journal, "enqueue", side_effect=RuntimeError("disk full")):
            with self.assertRaises(RuntimeError):
                self.provider.on_pre_compress([{"role": "user", "content": "evidence", "message_uid": "u1"}], require_checkpoint=True)

    def test_multibyte_evidence_respects_host_bytes_and_keeps_original_identity(self):
        import hashlib
        text = '汉' * 100000
        self.provider.on_pre_compress([{'role': 'user', 'content': text, 'message_uid': 'native-original'}], require_checkpoint=True)
        row = self.rows('message')[0]
        self.assertLessEqual(len(row['content'].encode()), 262144)
        self.assertTrue(row['completeness']['truncated'])
        self.assertEqual(row['completeness']['original_length'], len(text))
        self.assertEqual(row['completeness']['original_sha256'], hashlib.sha256(text.encode()).hexdigest())
        self.assertTrue(row['source_reference'].endswith('/native-original'))

    def test_multibyte_evidence_without_original_identity_cannot_claim_checkpoint(self):
        with self.assertRaisesRegex(ValueError, 'oversized_evidence_without_original_reference'):
            self.provider.on_pre_compress([{'role': 'user', 'content': '汉' * 100000}], require_checkpoint=True)

    def test_session_switch_updates_capture_parent(self):
        self.provider.on_session_switch("session-2", parent_session_id="session-1", reset=True)
        self.provider.sync_turn("user", "answer", session_id="session-2", messages=[{"role": "user", "content": "user", "message_uid": "u2"}])
        self.assertEqual(self.rows("message")[-1]["parent_session_id"], "session-1")

    def test_checkpoint_preserves_tool_prose_identity_without_replacing_full_evidence(self):
        row = {"role": "assistant", "content": "tool explanation", "message_uid": "a1", "tool_calls": [{"id": "repeat", "function": {"name": "terminal", "arguments": "{}"}}], "_tool_call_uids": {"repeat": "occurrence-1"}}
        self.provider.sync_turn("user", "tool explanation", messages=[row])
        normalized = {k: v for k, v in row.items() if k != "tool_calls"}
        self.provider.on_pre_compress([normalized], require_checkpoint=True)
        self.assertEqual(len(self.rows("message")), 1)
        self.assertEqual(self.rows("message")[0]["tool_call_uids"], {"repeat": "occurrence-1"})

    def test_same_native_uid_content_change_is_a_new_immutable_revision(self):
        self.provider.sync_turn("one", "answer", messages=[{"role": "user", "content": "one", "message_uid": "u1"}])
        self.provider.sync_turn("two", "answer", messages=[{"role": "user", "content": "two", "message_uid": "u1"}])
        rows = self.rows("message")
        self.assertEqual([r["source_revision"] for r in rows], [1, 2])
        self.assertEqual(len({r["event_id"] for r in rows}), 2)

    def test_turn_author_does_not_reassign_previous_users_in_accumulated_context(self):
        first = {"role": "user", "content": "first user message", "message_uid": "u1"}
        second = {"role": "user", "content": "second user message", "message_uid": "u2"}
        alice = {"id": "alice", "name": "Alice", "is_bot": False}
        bob = {"id": "bob", "name": "Bob", "is_bot": False}
        self.provider.sync_turn(first["content"], "answer", messages=[first], turn_author=alice)
        self.provider.sync_turn(second["content"], "answer", messages=[first, second], turn_author=bob)
        self.provider.on_pre_compress([first, second], require_checkpoint=True)
        rows = self.rows("message")
        self.assertEqual(len(rows), 2)
        self.assertEqual([row["author"]["id"] for row in rows], ["alice", "bob"])

    def test_legacy_equal_message_occurrences_are_not_content_deduplicated(self):
        rows = [{"role": "user", "content": "same"}, {"role": "user", "content": "same"}]
        self.provider.sync_turn("same", "answer", messages=rows)
        self.provider.on_pre_compress(rows, require_checkpoint=True)
        self.assertEqual(len(self.rows("message")), 2)
        self.assertTrue(all("message_uid" not in row for row in self.rows("message")))

    def test_standalone_legacy_turns_keep_distinct_callback_occurrences(self):
        self.provider.sync_turn("same", "answer")
        self.provider.sync_turn("same", "answer")
        self.assertEqual(len(self.rows("message")), 4)

    def test_old_raw_checkpoint_input_never_archives_tools_or_summary_as_direct_text(self):
        rows = [{"role": "system", "content": "instructions"}, {"role": "tool", "content": "output"}, {"role": "assistant", "content": "summary", "_compressed_summary": True}, {"role": "assistant", "content": "", "tool_calls": [{"id": "t1"}]}, {"role": "user", "content": "direct", "message_uid": "u1"}]
        self.provider.on_pre_compress(rows, require_checkpoint=True)
        self.assertEqual([row["content"] for row in self.rows("message")], ["direct"])

    def test_delayed_old_session_sync_does_not_take_new_parent(self):
        self.provider.on_session_switch("session-2", parent_session_id="session-1", reset=True)
        self.provider.sync_turn("old user", "old answer", session_id="session-1", messages=[{"role": "user", "content": "old user", "message_uid": "old"}])
        self.assertNotIn("parent_session_id", self.rows("message")[-1])

    def test_closed_provider_status_remains_readable(self):
        self.provider.shutdown()
        self.assertIn("canonical_committed", self.provider.delivery_status())

    def test_oversized_legacy_checkpoint_refuses_invented_original(self):
        self.provider._config["evidence_chars"] = 1024
        with self.assertRaisesRegex(ValueError, "without_original_reference"):
            self.provider.on_pre_compress([{"role": "user", "content": "x" * 1100}], require_checkpoint=True)
        self.assertEqual(self.rows("message"), [])

    def test_oversized_real_message_is_a_marked_excerpt_with_native_reference(self):
        self.provider._config["evidence_chars"] = 1024
        self.provider.on_pre_compress([{"role": "user", "content": "x" * 1100, "message_uid": "u1"}], require_checkpoint=True)
        row = self.rows("message")[0]
        self.assertTrue(row["completeness"]["truncated"])
        self.assertEqual(row["completeness"]["original_length"], 1100)
        self.assertEqual(len(row["content"]), 1024)
        self.assertTrue(row["source_reference"].endswith("/session-1/u1"))


if __name__ == "__main__":
    unittest.main()
