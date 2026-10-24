import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

spec = importlib.util.spec_from_file_location("backplane_memory", Path(__file__).parents[1] / "hermes" / "__init__.py")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)
smoke_spec = importlib.util.spec_from_file_location("backplane_memory_smoke", Path(__file__).parents[1] / "hermes" / "smoke_test.py")
smoke = importlib.util.module_from_spec(smoke_spec)
smoke_spec.loader.exec_module(smoke)

class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_args): return False
    def read(self, *args): return json.dumps(self.body).encode()

class HermesContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        (self.home / "memories").mkdir()
        self.write_source("memory", [])
        self.write_source("user", [])
        self.provider = self.new_provider()

    def new_provider(self, session="session-1", **kwargs):
        provider = plugin.BackplaneMemoryProvider()
        with patch.object(plugin,"_load_egress_scrubber",return_value=lambda text:text), patch.object(plugin.BackplaneMemoryProvider, "_start_worker", lambda s: None, create=True), patch.dict(plugin.os.environ, {"BACKPLANE_MEMORY_URL": "http://127.0.0.1:4222", "BACKPLANE_MEMORY_AGENT_ID": "hermes test"}):
            provider.initialize(session, hermes_home=str(self.home), cwd="/Users/gao/.dotfiles", **kwargs)
        self.addCleanup(provider.shutdown)
        return provider

    def write_source(self, target, entries):
        (self.home / "memories" / ("USER.md" if target == "user" else "MEMORY.md")).write_text("\n§\n".join(entries))

    def rows(self, suffix):
        return [json.loads(r["payload"]) for r in self.provider._journal.pending(limit=100) if r["path"].endswith(suffix)]

    def test_availability_and_system_prompt_are_local_static(self):
        with patch.object(plugin, "urlopen", side_effect=AssertionError("network forbidden")):
            self.assertTrue(self.provider.is_available())
            first = self.provider.system_prompt_block()
            self.assertIn("memory", first.lower())
            self.assertEqual(first, self.provider.system_prompt_block())

    def test_http_rejections_are_explicit_redacted_and_closed(self):
        for name,args in [("memory_save", {"content":"fact"}), ("memory_list",{}), ("memory_recall",{"query":"fact"}), ("memory_forget",{"id":"fact"})]:
            stream = io.BytesIO(b'{"ok":false,"error":"memory_scope_mismatch","detail":"private-credential"}')
            error = HTTPError("url",400,"private-credential",{},stream)
            with patch.object(plugin,"urlopen",side_effect=error), patch("sys.stderr",new_callable=io.StringIO) as stderr:
                self.assertTrue(self.provider.is_available())
                result=json.loads(self.provider.handle_tool_call(name,args))
            self.assertEqual(result,{"success":False,"error":"memory_scope_mismatch","http_status":400})
            self.assertNotIn("private-credential",json.dumps(result)+stderr.getvalue())
            self.assertTrue(stream.closed)

    def test_generic_tools_preserve_bound_scope_and_explicit_scope_authorization(self):
        with patch.object(plugin,"_post",return_value={"ok":True,"result":{"results":[]}}) as post:
            self.provider.handle_tool_call("memory_save",{"content":"fact"})
            payload=post.call_args.args[3]
            self.assertEqual(payload["session_id"],"session-1")
            self.assertNotIn("scope",payload)
            self.provider.handle_tool_call("memory_list",{"scope":"other-project"})
            self.assertEqual(post.call_args.args[3]["scope"],"other-project")

    def test_protocol_errors_do_not_look_like_empty_memories(self):
        for body in [{"ok":False,"error":"invalid_arguments"},[],{"ok":True,"result":"private-secret"}]:
            with patch.object(plugin,"urlopen",return_value=Response(body)), patch("sys.stderr",new_callable=io.StringIO):
                result=json.loads(self.provider.handle_tool_call("memory_list",{}))
            self.assertFalse(result.get("success",True))
            self.assertIn("error",result)
            self.assertNotIn("private-secret",json.dumps(result))

    def test_source_add_replace_remove_uses_one_entry_and_ordered_events(self):
        self.write_source("memory",["old fact"])
        self.provider.on_memory_write("add","memory","old fact",metadata={"session_id":"s1","tool_call_id":"reused"})
        self.write_source("memory",["new fact"])
        self.provider.on_memory_write("replace","memory","new fact",metadata={"previous_content":"old fact","session_id":"s2","tool_call_id":"reused"})
        self.write_source("memory",[])
        self.provider.on_memory_write("remove","memory","",metadata={"previous_content":"new fact","session_id":"s2","tool_call_id":"reused"})
        rows=self.rows("source_mutate")
        self.assertEqual([r["operation"] for r in rows],["upsert","upsert","withdraw"])
        self.assertEqual(len({r["entry_id"] for r in rows}),1)
        self.assertEqual(len({r["event_id"] for r in rows}),3)
        self.assertEqual([r["revision"] for r in rows],sorted(r["revision"] for r in rows))
        self.assertEqual(rows[1]["provenance"]["session_id"],"s2")
        self.assertFalse(self.provider._journal.db.execute("SELECT count(*) FROM source_entries WHERE active=1").fetchone()[0])

    def test_duplicate_add_and_late_callback_do_not_resurrect(self):
        self.write_source("memory",["fact"])
        self.provider.on_memory_write("add","memory","fact")
        self.provider.on_memory_write("add","memory","fact")
        self.write_source("memory",[])
        self.provider.on_memory_write("remove","memory","",metadata={"previous_content":"fact"})
        self.provider.on_memory_write("add","memory","fact")
        self.assertEqual([r["operation"] for r in self.rows("source_mutate")],["upsert","withdraw"])

    def test_batch_chain_keeps_original_entry_when_file_already_has_final_value(self):
        self.write_source("memory",["old"])
        self.provider.on_memory_write("add","memory","old")
        original=self.rows("source_mutate")[0]["entry_id"]
        self.write_source("memory",["third"])
        self.provider.on_memory_write("replace","memory","new",metadata={"previous_content":"old","tool_call_id":"shared"})
        self.provider.shutdown()
        self.provider=self.new_provider()
        self.provider.on_memory_write("replace","memory","third",metadata={"previous_content":"new","tool_call_id":"shared"})
        final=dict(self.provider._journal.db.execute("SELECT * FROM source_entries WHERE active=1").fetchone())
        self.assertEqual(final["entry_id"],original)
        self.assertEqual(final["content"],"third")
        self.assertFalse(any(row.get("content")=="new" for row in self.rows("source_mutate")))
        before=len(self.rows("source_mutate"))
        self.provider.on_memory_write("replace","memory","new",metadata={"previous_content":"old","tool_call_id":"shared"})
        self.assertEqual(len(self.rows("source_mutate")),before)

    def test_unreadable_source_is_pending_reconciliation_not_withdrawal(self):
        self.write_source("memory",["fact"])
        self.provider.on_memory_write("add","memory","fact")
        (self.home/"memories"/"MEMORY.md").write_bytes(b"\xff")
        self.provider.on_memory_write("remove","memory","",metadata={"previous_content":"fact"})
        self.assertEqual([r["operation"] for r in self.rows("source_mutate")],["upsert"])
        self.assertGreater(self.provider.delivery_status()["pending_reconciliation"],0)

    def test_native_snapshot_scrubs_wire_and_resolves_scrubbed_full_previous(self):
        secret="synthetic-private-secret"
        self.provider._native_scrubber=lambda value:value.replace(secret,"[redacted]")
        self.write_source("memory",["old "+secret])
        self.provider.on_memory_write("add","memory","old [redacted]")
        original=self.rows("source_mutate")[0]["entry_id"]
        self.write_source("memory",["new "+secret])
        self.provider.on_memory_write("replace","memory","new [redacted]",metadata={"previous_content":"old [redacted]"})
        rows=self.rows("source_mutate")
        self.assertEqual(rows[-1]["entry_id"],original)
        self.assertEqual(rows[-1]["content"],"new [redacted]")
        self.assertNotIn(secret,json.dumps(self.rows("source_mutate")+self.rows("source_reconcile")))

    def test_scrub_collision_keeps_independent_source_entries(self):
        self.provider._native_scrubber=lambda value:value.replace("secret-A","[redacted]").replace("secret-B","[redacted]")
        self.write_source("memory",["fact secret-A","fact secret-B"])
        self.provider.on_memory_write("add","memory","fact [redacted]")
        rows=self.rows("source_mutate")
        self.assertEqual(len(rows),2)
        self.assertEqual(len({row["entry_id"] for row in rows}),2)
        self.assertEqual({row["content"] for row in rows},{"fact [redacted]"})

    def test_unavailable_native_scrub_retains_observation_without_wire_fallback(self):
        self.provider._native_scrubber=None
        self.write_source("memory",["private native value"])
        self.provider.on_memory_write("add","memory","safe callback")
        self.assertEqual(self.rows("source_mutate"),[])
        self.assertGreater(self.provider.delivery_status()["pending_reconciliation"],0)
        self.assertEqual(self.provider.delivery_status()["native_egress"],"unavailable")

    def test_unknown_previous_content_uses_snapshot_without_guessing_identity(self):
        self.write_source("memory",["first","second"])
        self.provider.on_memory_write("add","memory","first")
        self.write_source("memory",["second","edited"])
        self.provider.on_memory_write("replace","memory","edited",metadata={"old_text":"fir"})
        rows=self.rows("source_mutate")
        old=next(r for r in rows if r.get("content")=="first")
        new=next(r for r in rows if r.get("content")=="edited")
        self.assertNotEqual(old["entry_id"],new["entry_id"])
        self.assertTrue(any(r["operation"]=="withdraw" and r["entry_id"]==old["entry_id"] for r in rows))

    def test_message_occurrences_and_checkpoint_overlap_are_durable(self):
        messages=[{"role":"user","content":"same","message_uid":"u1"},{"role":"assistant","content":"a guess","message_uid":"a1"},{"role":"user","content":"same","message_uid":"u2"}]
        before=copy.deepcopy(messages)
        self.provider.sync_turn("same","a guess",session_id="session-1",messages=messages)
        first=self.rows("message")
        self.assertEqual([r["message_uid"] for r in first],["u1","a1","u2"])
        self.assertEqual([r["role"] for r in first],["user","assistant","user"])
        reference=self.provider.on_pre_compress(messages,require_checkpoint=True)
        self.assertIsInstance(reference,str)
        self.assertEqual(messages,before)
        self.assertEqual(len(self.rows("message")),3)

    def test_checkpoint_local_persistence_failure_raises(self):
        self.assertEqual(self.provider.pre_compress_checkpoint_api_version,2)
        with patch.object(self.provider._journal,"enqueue",side_effect=RuntimeError("disk full")):
            with self.assertRaises(RuntimeError):
                self.provider.on_pre_compress([{"role":"user","content":"evidence","message_uid":"u1"}],require_checkpoint=True)

    def test_multibyte_evidence_respects_host_bytes_and_keeps_original_identity(self):
        import hashlib
        text='汉'*100000
        self.provider.on_pre_compress([{'role':'user','content':text,'message_uid':'native-original'}],require_checkpoint=True)
        row=self.rows('message')[0]
        self.assertLessEqual(len(row['content'].encode()),262144)
        self.assertTrue(row['completeness']['truncated'])
        self.assertEqual(row['completeness']['original_length'],len(text))
        self.assertEqual(row['completeness']['original_sha256'],hashlib.sha256(text.encode()).hexdigest())
        self.assertTrue(row['source_reference'].endswith('/native-original'))

    def test_multibyte_evidence_without_original_identity_cannot_claim_checkpoint(self):
        with self.assertRaisesRegex(ValueError,'oversized_evidence_without_original_reference'):
            self.provider.on_pre_compress([{'role':'user','content':'汉'*100000}],require_checkpoint=True)

    def test_flush_does_not_succeed_with_pending_native_reconciliation(self):
        status={**self.provider.delivery_status(),'local_pending':0,'host_accepted':0,'capture_deferred':0,'rejected':0,'pending_reconciliation':1}
        with patch.object(self.provider,'delivery_status',return_value=status):
            self.assertFalse(self.provider.flush(timeout=0,canonical=True)['success'])

    def test_session_switch_updates_explicit_save_and_capture_without_rebinding(self):
        source=self.provider._source("memory")
        self.provider.on_session_switch("session-2",parent_session_id="session-1",reset=True)
        self.assertEqual(self.provider._source("memory"),source)
        with patch.object(plugin,"_post",return_value={"ok":True,"result":{"id":"x"}}) as post:
            self.provider.handle_tool_call("memory_save",{"content":"fact"})
            self.assertEqual(post.call_args.args[3]["session_id"],"session-2")
        self.provider.sync_turn("user","answer",session_id="session-2",messages=[{"role":"user","content":"user","message_uid":"u2"}])
        self.assertEqual(self.rows("message")[-1]["parent_session_id"],"session-1")

    def test_nonprimary_context_skips_automatic_writes(self):
        provider=self.new_provider(agent_context="subagent")
        before=provider.delivery_status()["local_pending"]
        provider.sync_turn("user","assistant",messages=[{"role":"user","content":"user","message_uid":"u1"}])
        self.assertEqual(provider.delivery_status()["local_pending"],before)

    def test_missing_source_file_never_means_empty_snapshot(self):
        self.write_source("memory",["fact"])
        self.provider.on_memory_write("add","memory","fact")
        (self.home/"memories"/"MEMORY.md").unlink()
        self.provider.on_memory_write("remove","memory","",metadata={"previous_content":"fact"})
        self.assertEqual([r["operation"] for r in self.rows("source_mutate")],["upsert"])

    def test_checkpoint_preserves_tool_prose_identity_without_replacing_full_evidence(self):
        row={"role":"assistant","content":"tool explanation","message_uid":"a1","tool_calls":[{"id":"repeat","function":{"name":"terminal","arguments":"{}"}}],"_tool_call_uids":{"repeat":"occurrence-1"}}
        self.provider.sync_turn("user","tool explanation",messages=[row])
        normalized={k:v for k,v in row.items() if k!="tool_calls"}
        self.provider.on_pre_compress([normalized],require_checkpoint=True)
        self.assertEqual(len(self.rows("message")),1)
        self.assertEqual(self.rows("message")[0]["tool_call_uids"],{"repeat":"occurrence-1"})

    def test_same_native_uid_content_change_is_a_new_immutable_revision(self):
        self.provider.sync_turn("one","answer",messages=[{"role":"user","content":"one","message_uid":"u1"}])
        self.provider.sync_turn("two","answer",messages=[{"role":"user","content":"two","message_uid":"u1"}])
        rows=self.rows("message")
        self.assertEqual([r["source_revision"] for r in rows],[1,2])
        self.assertEqual(len({r["event_id"] for r in rows}),2)

    def test_turn_author_does_not_reassign_previous_users_in_accumulated_context(self):
        first={"role":"user","content":"first user message","message_uid":"u1"}
        second={"role":"user","content":"second user message","message_uid":"u2"}
        alice={"id":"alice","name":"Alice","is_bot":False}
        bob={"id":"bob","name":"Bob","is_bot":False}
        self.provider.sync_turn(first["content"],"answer",messages=[first],turn_author=alice)
        self.provider.sync_turn(second["content"],"answer",messages=[first,second],turn_author=bob)
        self.provider.on_pre_compress([first,second],require_checkpoint=True)
        rows=self.rows("message")
        self.assertEqual(len(rows),2)
        self.assertEqual([row["author"]["id"] for row in rows],["alice","bob"])

    def test_legacy_equal_message_occurrences_are_not_content_deduplicated(self):
        rows=[{"role":"user","content":"same"},{"role":"user","content":"same"}]
        self.provider.sync_turn("same","answer",messages=rows)
        self.provider.on_pre_compress(rows,require_checkpoint=True)
        self.assertEqual(len(self.rows("message")),2)
        self.assertTrue(all("message_uid" not in row for row in self.rows("message")))

    def test_standalone_legacy_turns_keep_distinct_callback_occurrences(self):
        self.provider.sync_turn("same","answer")
        self.provider.sync_turn("same","answer")
        self.assertEqual(len(self.rows("message")),4)

    def test_old_raw_checkpoint_input_never_archives_tools_or_summary_as_direct_text(self):
        rows=[{"role":"system","content":"instructions"},{"role":"tool","content":"output"},{"role":"assistant","content":"summary","_compressed_summary":True},{"role":"assistant","content":"","tool_calls":[{"id":"t1"}]},{"role":"user","content":"direct","message_uid":"u1"}]
        self.provider.on_pre_compress(rows,require_checkpoint=True)
        self.assertEqual([row["content"] for row in self.rows("message")],["direct"])

    def test_same_text_in_native_targets_is_separate_source_support(self):
        for target in ("memory","user"):
            self.write_source(target,["shared fact"])
            self.provider.on_memory_write("add",target,"shared fact")
        rows=self.rows("source_mutate")
        self.assertEqual(len({row["entry_id"] for row in rows}),2)
        self.assertEqual({row["source"]["target"] for row in rows},{"memory","user"})

    def test_delayed_old_session_sync_does_not_take_new_parent(self):
        self.provider.on_session_switch("session-2",parent_session_id="session-1",reset=True)
        self.provider.sync_turn("old user","old answer",session_id="session-1",messages=[{"role":"user","content":"old user","message_uid":"old"}])
        self.assertNotIn("parent_session_id",self.rows("message")[-1])

    def test_unsupported_legacy_update_never_appends_remember(self):
        with patch.object(plugin,"_post",side_effect=AssertionError("no append fallback")):
            with self.assertRaisesRegex(ValueError,"unsupported_native_callback"):
                self.provider.on_memory_write("update","memory","legacy")

    def test_source_snapshot_digests_and_empty_target_are_complete(self):
        import hashlib
        events=self.rows("source_reconcile")
        starts=[row for row in events if row["phase"]=="begin"]
        self.assertEqual(len(starts),2)
        for row in starts:
            self.assertEqual(row["snapshot_hash"],hashlib.sha256(b"[]").hexdigest())
            self.assertEqual(row["entry_count"],0)
            self.assertEqual(row["page_count"],0)

    def test_closed_provider_status_remains_readable(self):
        self.provider.shutdown()
        self.assertIn("canonical_committed",self.provider.delivery_status())

    def test_oversized_legacy_checkpoint_refuses_invented_original(self):
        self.provider._config["evidence_chars"]=1024
        with self.assertRaisesRegex(ValueError,"without_original_reference"):
            self.provider.on_pre_compress([{"role":"user","content":"x"*1100}],require_checkpoint=True)
        self.assertEqual(self.rows("message"),[])

    def test_oversized_real_message_is_a_marked_excerpt_with_native_reference(self):
        self.provider._config["evidence_chars"]=1024
        self.provider.on_pre_compress([{"role":"user","content":"x"*1100,"message_uid":"u1"}],require_checkpoint=True)
        row=self.rows("message")[0]
        self.assertTrue(row["completeness"]["truncated"])
        self.assertEqual(row["completeness"]["original_length"],1100)
        self.assertEqual(len(row["content"]),1024)
        self.assertTrue(row["source_reference"].endswith("/session-1/u1"))

class SmokeContractTest(unittest.TestCase):
    def test_failed_or_malformed_reads_cannot_prove_deletion(self):
        for result in [
            {"success": False, "error": "request_failed"},
            {"success": False, "error": "http_error", "http_status": 500},
            {}, {"results": None}, {"results": {}},
            {"results": [], "provisional_results": None},
            {"results": [], "provisional_results": {}},
        ]:
            with self.subTest(result=result), self.assertRaises(AssertionError):
                smoke.contains_record(result, "test fact")
        self.assertFalse(smoke.contains_record({"results": []}, "test fact"))
        self.assertFalse(smoke.contains_record({"results": [], "provisional_results": []}, "test fact"))

    def test_scope_rejection_requires_a_scope_error_and_http_400(self):
        for result in [
            {"success": False, "error": "request_failed"},
            {"success": False, "error": "http_error", "http_status": 500},
            {"success": False, "error": "invalid_scope", "http_status": 500},
            {"success": False, "error": "request_failed", "http_status": 400},
        ]:
            with self.subTest(result=result), self.assertRaises(AssertionError):
                smoke.validate_scope_rejection(result)
        for code in ["invalid_scope", "unknown_scope", "invalid_arguments", "invalid_request"]:
            smoke.validate_scope_rejection({"success": False, "error": code, "http_status": 400})


if __name__ == "__main__":
    unittest.main()
