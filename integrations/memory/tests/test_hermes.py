import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


spec = importlib.util.spec_from_file_location(
    "backplane_memory", Path(__file__).parents[1] / "hermes" / "__init__.py"
)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

smoke_spec = importlib.util.spec_from_file_location(
    "backplane_memory_smoke", Path(__file__).parents[1] / "hermes" / "smoke_test.py"
)
smoke = importlib.util.module_from_spec(smoke_spec)
smoke_spec.loader.exec_module(smoke)


class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_args): return False
    def read(self): return json.dumps(self.body).encode()


class HermesContractTest(unittest.TestCase):
    def setUp(self):
        self.provider = plugin.BackplaneMemoryProvider()
        with patch.dict(plugin.os.environ, {"BACKPLANE_MEMORY_URL": "http://127.0.0.1:4222",
                                            "BACKPLANE_MEMORY_AGENT_ID": "hermes test"}):
            self.provider.initialize("session-1", cwd="/Users/gao/.dotfiles")

    def test_cwd_never_overrides_bound_scope(self):
        calls = []

        def post(_base, _agent_id, method, args):
            calls.append((method, args))
            return {"ok": True, "result": {"results": []}}

        with patch.object(plugin, "_post", side_effect=post), \
             patch.object(plugin, "_post_bg", side_effect=post):
            self.provider.system_prompt_block()
            self.provider.prefetch("fact")
            self.provider.queue_prefetch("fact")
            self.provider.handle_tool_call("memory_recall", {"query": "fact"})
            self.provider.handle_tool_call("memory_save", {"content": "fact"})
            self.provider.handle_tool_call("memory_list", {})
            self.provider.sync_turn("user", "assistant")
            self.provider.on_pre_compress([{"role": "user", "content": "fact"}])
            self.provider.on_memory_write("add", "target", "fact")
        self.assertEqual(len(calls), 9)
        for method, args in calls:
            self.assertNotIn("scope", args, method)

    def test_http_rejections_are_explicit_and_redacted(self):
        for name, args in [("memory_save", {"content": "fact"}),
                           ("memory_list", {}),
                           ("memory_recall", {"query": "fact"}),
                           ("memory_forget", {"id": "fact"})]:
            error = HTTPError("url", 400, "private-secret", {},
                              io.BytesIO(b'{"ok":false,"error":"invalid_scope","detail":"private-secret"}'))
            with patch.object(plugin, "urlopen", side_effect=error), \
                 patch("sys.stderr", new_callable=io.StringIO) as stderr:
                result = json.loads(self.provider.handle_tool_call(name, args))
            self.assertEqual(result.get("success"), False)
            self.assertEqual(result.get("error"), "invalid_scope")
            self.assertEqual(result.get("http_status"), 400)
            self.assertNotIn("private-secret", json.dumps(result) + stderr.getvalue())

    def test_availability_probes_the_api_without_writing(self):
        calls = []

        def urlopen(request, timeout):
            calls.append((request.full_url, json.loads(request.data)))
            return Response({"ok": True, "result": {"results": []}})

        with patch.object(plugin, "urlopen", side_effect=urlopen):
            self.assertTrue(self.provider.is_available())
        self.assertEqual(calls, [("http://127.0.0.1:4222/memory/hermes%20test/call/list", {"limit": 1})])
        with patch.object(plugin, "urlopen", side_effect=URLError("private-secret")), \
             patch("sys.stderr", new_callable=io.StringIO):
            self.assertFalse(self.provider.is_available())

    def test_scope_mismatch_disables_availability_and_preserves_safe_tool_error(self):
        def reject(_request, timeout):
            raise HTTPError("url", 400, "private-credential", {}, io.BytesIO(
                b'{"ok":false,"error":"memory_scope_mismatch","detail":"private-credential"}'
            ))

        with patch.object(plugin, "urlopen", side_effect=reject), \
             patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertFalse(self.provider.is_available())
            result = json.loads(self.provider.handle_tool_call("memory_save", {"content": "fact"}))
        self.assertEqual(result, {"success": False, "error": "memory_scope_mismatch", "http_status": 400})
        self.assertIn("memory_scope_mismatch", stderr.getvalue())
        self.assertNotIn("private-credential", json.dumps(result) + stderr.getvalue())

    def test_explicit_scope_is_forwarded_for_server_authorization(self):
        with patch.object(plugin, "_post", return_value={"ok": True, "result": {"results": []}}) as post:
            self.provider.handle_tool_call("memory_list", {"scope": "other-project"})
        self.assertEqual(post.call_args.args[3]["scope"], "other-project")

    def test_protocol_errors_do_not_look_like_empty_memories(self):
        for body in [{"ok": False, "error": "invalid_arguments"}, [],
                     {"ok": True, "result": "private-secret"}]:
            with patch.object(plugin, "urlopen", return_value=Response(body)), \
                 patch("sys.stderr", new_callable=io.StringIO):
                result = json.loads(self.provider.handle_tool_call("memory_list", {}))
            self.assertFalse(result.get("success", True))
            self.assertIn("error", result)
            self.assertNotIn("private-secret", json.dumps(result))

    def test_pending_list_rows_are_rendered_separately_without_changing_tool_results(self):
        result = {
            "results": [{"id": "canonical-1", "content": "canonical fact"}],
            "provisional_results": [{"id": "local-1", "content": "pending fact",
                                     "provisional": True, "authority": "provisional"}],
            "cursor": "next", "authority": "canonical_with_provisional",
        }
        with patch.object(plugin, "_post", return_value={"ok": True, "result": result}):
            tool_result = json.loads(self.provider.handle_tool_call("memory_list", {}))
            self.assertEqual(tool_result, result)
            prompt = self.provider.system_prompt_block()
            self.assertIn("canonical fact", prompt)
            self.assertIn("Pending local memories (awaiting canonical acknowledgment):", prompt)
            self.assertIn("pending fact", prompt)
            self.assertLess(prompt.index("canonical fact"), prompt.index("Pending local memories"))
            result["results"] = []
            self.assertIn("pending fact", self.provider.system_prompt_block())

    def test_provisional_recall_and_offline_list_are_marked_in_prompt_context(self):
        for flags in [{"provisional": True}, {"authority": "provisional"}]:
            result = {"results": [{"id": "local-1", "content": "pending fact", **flags}]}
            with patch.object(plugin, "_post", return_value={"ok": True, "result": result}):
                self.assertIn("[pending local memory]", self.provider.prefetch("fact"))
                messages = [{"role": "user", "content": "fact"}]
                self.provider.on_pre_compress(messages)
                self.assertIn("[pending local memory]", messages[0]["content"])
                self.assertIn("Pending local memories", self.provider.system_prompt_block())


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
