"""Final context packing through the provider's actual recall/cache path."""

import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from test_hermes_runtime import current, load_plugin


plugin = load_plugin()


class ContextMergeTest(unittest.TestCase):
    def test_canonical_and_provisional_entries_share_one_whole_entry_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "memories").mkdir()
            for target in ("MEMORY.md", "USER.md"):
                (home / "memories" / target).write_text("")
            provider = plugin.BackplaneMemoryProvider()
            with patch.object(plugin, "_load_egress_scrubber", return_value=lambda text: text), \
                 patch.object(plugin.BackplaneMemoryProvider, "_start_worker", lambda self: None), \
                 patch.dict(plugin.os.environ, {}, clear=True):
                provider.initialize("merge-session", hermes_home=str(home))
            try:
                provider._config["context_token_budget"] = 320
                canonical = current("alpha canonical record " + "界" * 8,
                                    canonical_id="canonical", independent_support=True)
                provisional = current("alpha provisional record " + "界" * 8,
                                      canonical_id="pending", trust="candidate_inference",
                                      authority="provisional", provisional=True,
                                      independent_support=True)
                overflow = current("alpha overflow " + "x" * 90, canonical_id="overflow")
                # The public response separates canonical and provisional results.
                # Raw content fits; references, trust labels and UTF-8 overhead
                # must be counted after merge, with duplicate identities removed.
                self.assertLess(sum(len(row["content"].encode())
                                    for row in (canonical, provisional, overflow)), 320)
                response = {"ok": True, "result": {
                    "results": [canonical],
                    "provisional_results": [dict(canonical), provisional, overflow],
                }}
                provider.queue_prefetch("alpha")
                key, value = provider._prefetch_jobs.popitem(last=False)
                with patch.object(plugin, "_post", return_value=response) as transport:
                    provider._fetch_context(key, value)
                with patch.object(plugin, "_post", side_effect=AssertionError("cache must be consumed locally")):
                    text = provider.prefetch("alpha")
                self.assertEqual(transport.call_args.args[2], "recall")
                self.assertEqual(transport.call_args.args[3]["token_budget"], 320)
                self.assertLessEqual(len(text.encode()), 320)
                self.assertEqual(len(text.splitlines()), 2)
                self.assertEqual(text.count(canonical["content"]), 1)
                self.assertIn(provisional["content"], text)
                self.assertNotIn("alpha overflow", text)
                self.assertIn("candidate inference; pending local memory", text)
                self.assertEqual({line.split("] ", 1)[1] for line in text.splitlines()},
                                 {canonical["content"], provisional["content"]})
            finally:
                provider.shutdown()


if __name__ == "__main__":
    unittest.main()
