"""Actual supported session callbacks preserve occurrence and parent provenance."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_hermes_delivery import load_plugin


plugin = load_plugin()


class SessionContinuityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        (self.home / "memories").mkdir()
        for target in ("MEMORY.md", "USER.md"):
            (self.home / "memories" / target).write_text("")
        self.provider = self.build("original")

    def build(self, session):
        provider = plugin.BackplaneMemoryProvider()
        with patch.object(plugin, "_load_egress_scrubber", return_value=lambda text: text), \
             patch.object(plugin.BackplaneMemoryProvider, "_start_worker", lambda self: None), \
             patch.dict(plugin.os.environ, {}, clear=True):
            provider.initialize(session, hermes_home=str(self.home))
        self.addCleanup(provider.shutdown)
        return provider

    def messages(self):
        return [json.loads(row[0]) for row in self.provider._journal.db.execute(
            "SELECT payload FROM delivery WHERE path LIKE '%/message' ORDER BY queue_sequence")]

    def sync(self, rows, **kwargs):
        before = copy.deepcopy(rows)
        self.provider.sync_turn("", "", messages=rows, **kwargs)
        self.assertEqual(rows, before)

    def test_resume_and_growing_snapshots_preserve_stable_occurrences(self):
        first = {"role": "user", "content": "same text", "message_uid": "user-1"}
        second = {"role": "user", "content": "same text", "message_uid": "user-2"}
        self.sync([first])
        original = self.messages()[0]
        source = self.provider._source("memory")
        self.provider.shutdown()
        self.provider = self.build("original")
        self.sync([first])
        self.sync([first, second])
        self.sync([first, second])
        rows = self.messages()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], original)
        self.assertEqual([row["message_uid"] for row in rows], ["user-1", "user-2"])
        self.assertEqual({row["session_id"] for row in rows}, {"original"})
        self.assertEqual(self.provider._source("memory"), source)

    def test_branch_shorter_rewound_snapshot_revision_and_delayed_old_callback(self):
        first = {"role": "user", "content": "first", "message_uid": "u1"}
        second = {"role": "assistant", "content": "second", "message_uid": "a1"}
        self.sync([first, second])
        self.provider.on_session_switch("branch", parent_session_id="original")
        self.sync([first, second])
        branch = self.messages()[2:]
        self.assertEqual({row["session_id"] for row in branch}, {"branch"})
        self.assertTrue(all(row["parent_session_id"] == "original" for row in branch))
        self.assertEqual(len({row["event_id"] for row in self.messages()}), 4)

        # The supported callback provides a flag, not a historical deletion cursor.
        # A shorter snapshot preserves previously captured evidence; a changed
        # native UID is a new immutable revision of that occurrence.
        self.provider.on_session_switch("branch", parent_session_id="original", rewound=True)
        self.sync([first])
        self.assertEqual(len(self.messages()), 4)
        revised = dict(first, content="first corrected")
        later = {"role": "user", "content": "later", "message_uid": "u3"}
        self.sync([revised, later])
        rows = self.messages()
        self.assertEqual(len(rows), 6)
        self.assertEqual(rows[-2]["source_revision"], 2)
        self.assertEqual(rows[-2]["message_uid"], "u1")
        self.assertEqual(rows[-1]["session_id"], "branch")
        self.assertEqual(rows[-1]["parent_session_id"], "original")
        with patch.object(plugin, "_post", return_value={"ok": True, "result": {"id": "saved"}}) as post:
            self.provider.handle_tool_call("memory_save", {"content": "later native write"})
        self.assertEqual(post.call_args.args[3]["session_id"], "branch")

        old_later = {"role": "user", "content": "late original work", "message_uid": "old-u3"}
        self.sync([first, second, old_later], session_id="original")
        delayed = self.messages()[-1]
        self.assertEqual(delayed["session_id"], "original")
        self.assertNotIn("parent_session_id", delayed)
        self.assertEqual(self.provider._session_id, "branch")
        self.assertEqual(len(self.messages()), 7)


if __name__ == "__main__":
    unittest.main()
