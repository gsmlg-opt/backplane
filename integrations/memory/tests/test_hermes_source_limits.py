"""Provider preparation matches the frozen BEAM source command boundaries."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_hermes_delivery import load_plugin

plugin=load_plugin()


class SourceLimitsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name)
        (self.home/'backplane-memory.json').write_text(json.dumps({'journal_bytes':268435456}))
        (self.home/'memories').mkdir()
        for name in ('MEMORY.md','USER.md'):
            (self.home/'memories'/name).write_text('')
        self.provider=plugin.BackplaneMemoryProvider()
        with patch.object(plugin,'_load_egress_scrubber',return_value=lambda value:value),patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda self:None),patch.dict(plugin.os.environ,{},clear=True):
            self.provider.initialize('s1',hermes_home=str(self.home))
        self.addCleanup(self.provider.shutdown)

    def reject_without_journal_or_identity_changes(self,content,metadata=None):
        before=list(self.provider._journal.db.execute('SELECT * FROM delivery'))
        (self.home/'memories'/'MEMORY.md').write_text(content)
        with patch.object(self.provider._journal,'enqueue',wraps=self.provider._journal.enqueue) as enqueue:
            result=plugin.source.capture_callback(self.provider,'add','memory',content,metadata or {})
        self.assertFalse(result['complete'])
        self.assertEqual(enqueue.call_count,0)
        self.assertEqual([tuple(r) for r in self.provider._journal.db.execute('SELECT * FROM delivery')],[tuple(r) for r in before])
        self.assertEqual(self.provider._journal.db.execute('SELECT count(*) FROM source_entries').fetchone()[0],0)
        self.assertEqual(self.provider._journal.db.execute('SELECT count(*) FROM callbacks WHERE processed=0').fetchone()[0],1)

    def test_invalid_provenance_never_partially_queues_a_source_change(self):
        for metadata in ({'role':'invented'}, {'cwd':'汉'*1400}, {'author':{'confidence':0.5}},
                         {'author':{'nested':{'host_id':'forged'}}}, {'repository_sources':[{}]*33},
                         {'repository_sources':['not-a-map']}):
            with self.subTest(metadata_shape=list(metadata)):
                self.reject_without_journal_or_identity_changes('fact',metadata)
                self.provider._journal.db.execute('DELETE FROM callbacks')

    def test_expanded_redaction_and_nul_content_are_rejected_without_cropping(self):
        self.provider._native_scrubber=lambda value:'汉'*90000 if value=='fact' else value
        self.reject_without_journal_or_identity_changes('fact')
        self.provider._journal.db.execute('DELETE FROM callbacks')
        self.provider._native_scrubber=lambda value:value
        self.reject_without_journal_or_identity_changes('contains\x00nul')

    def test_complete_command_limit_includes_provenance_and_envelope(self):
        self.reject_without_journal_or_identity_changes('x'*20000,{'author':{'name':'x'*465000}})

    def test_snapshot_total_includes_repeated_provenance_before_any_enqueue(self):
        entries=[str(index)+':'+('x'*200000) for index in range(60)]
        (self.home/'memories'/'MEMORY.md').write_text('\n§\n'.join(entries))
        before=self.provider._journal.db.execute('SELECT count(*) FROM delivery').fetchone()[0]
        with patch.object(self.provider._journal,'enqueue',wraps=self.provider._journal.enqueue) as enqueue:
            result=plugin.source.capture_callback(self.provider,'add','memory',entries[0],{'author':{'name':'x'*100000}})
        self.assertFalse(result['complete'])
        self.assertEqual(enqueue.call_count,0)
        self.assertEqual(self.provider._journal.db.execute('SELECT count(*) FROM delivery').fetchone()[0],before)
        self.assertEqual(self.provider._journal.db.execute('SELECT count(*) FROM source_entries').fetchone()[0],0)

    def test_supported_utf8_entries_are_whole_and_pages_match_full_wire_limit(self):
        entries=[str(index)+':'+('汉'*70000) for index in range(3)]
        (self.home/'memories'/'MEMORY.md').write_text('\n§\n'.join(entries))
        result=plugin.source.capture_callback(self.provider,'add','memory',entries[0],{'author':{'name':'operator'}})
        self.assertTrue(result['complete'])
        pages=[]
        for row in self.provider._journal.pending(limit=100):
            if row['path'].endswith('source_mutate') or row['path'].endswith('source_reconcile'):
                self.assertLessEqual(len(row['payload'].encode()),480000)
                body=json.loads(row['payload'])
                if body.get('phase')=='page' and body['source']['target']=='memory':
                    pages.append(body)
        self.assertEqual([entry['content'] for page in pages for entry in page['entries']],entries)


if __name__=='__main__':
    unittest.main()
