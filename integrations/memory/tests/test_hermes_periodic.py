"""Tracked worker reconciliation with a deterministic clock and no timed sleeps."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_hermes_delivery import load_plugin

plugin=load_plugin()


class PeriodicSourceTest(unittest.TestCase):
    def test_appearing_and_changed_native_files_converge_without_callbacks(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp)
            (home/'memories').mkdir()
            provider=plugin.BackplaneMemoryProvider()
            clock=[0.0]
            with patch.object(plugin,'_load_egress_scrubber',return_value=lambda value:value),patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda self:None),patch.dict(plugin.os.environ,{},clear=True):
                provider.initialize('s1',hermes_home=str(home))
            self.addCleanup(provider.shutdown)
            snapshots=[]
            class Wake:
                def set(self): pass
                def clear(self): pass
                def wait(self,timeout):
                    snapshots.append([row[0] for row in provider._journal.db.execute('SELECT content FROM source_entries WHERE active=1 ORDER BY content')])
                    if len(snapshots)==1:
                        (home/'memories'/'MEMORY.md').write_text('first native fact')
                    elif len(snapshots)==2:
                        (home/'memories'/'MEMORY.md').write_text('changed without callback')
                    elif len(snapshots)==3:
                        (home/'memories'/'MEMORY.md').unlink()
                    else:
                        provider._stopping.set()
                    clock[0]+=30
            provider._wake=Wake()
            with patch.object(plugin.time,'monotonic',side_effect=lambda:clock[0]),patch.object(provider,'_deliver_once',return_value=False):
                provider._start_worker()
                provider._worker.join(timeout=3)
                if provider._worker.is_alive():
                    provider._stopping.set()
                    provider._worker.join(timeout=3)
                self.assertFalse(provider._worker.is_alive())
            self.assertEqual(snapshots,[[],['first native fact'],['changed without callback'],['changed without callback']])
            self.assertEqual(provider._journal.db.execute('SELECT count(*) FROM callbacks').fetchone()[0],0)
            self.assertEqual(provider.delivery_status()['source_snapshots']['memory'],'source_snapshot_unavailable')
            self.assertTrue(provider._worker_done)

    def test_periodic_worker_does_not_capture_nonprimary_native_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);(home/'memories').mkdir();(home/'memories'/'MEMORY.md').write_text('not automatic')
            provider=plugin.BackplaneMemoryProvider()
            with patch.object(plugin,'_load_egress_scrubber',return_value=lambda value:value),patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda self:None),patch.dict(plugin.os.environ,{},clear=True):
                provider.initialize('s1',hermes_home=str(home),agent_context='subagent')
            self.addCleanup(provider.shutdown)
            with patch.object(provider,'_deliver_once',return_value=False),patch.object(provider._wake,'wait',side_effect=lambda timeout:provider._stopping.set()):
                provider._worker_loop()
            self.assertEqual(provider._journal.db.execute('SELECT count(*) FROM source_entries').fetchone()[0],0)
