import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('hermes_rollout',Path(__file__).parents[1]/'hermes'/'rollout.py')
rollout=importlib.util.module_from_spec(spec);spec.loader.exec_module(rollout)

class RolloutTest(unittest.TestCase):
    def test_dry_run_does_not_create_delivery_journal_or_authorize_missing_withdrawal(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);(home/'memories').mkdir();(home/'memories'/'MEMORY.md').write_text('first\n§\nsecond')
            report=rollout.inspect_profile(home)
            self.assertTrue(report['dry_run'])
            self.assertEqual(report['native_sources'][0]['entries'],2)
            self.assertFalse(report['native_sources'][1]['complete'])
            self.assertFalse(report['native_sources'][1]['withdrawals_authorized'])
            self.assertFalse((home/'backplane-memory').exists())
            self.assertEqual((home/'memories'/'MEMORY.md').read_text(),'first\n§\nsecond')

    def test_legacy_review_preserves_ambiguity_and_never_invents_originals(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'legacy.json'
            path.write_text(json.dumps([{'id':'one','session_id':'s1','metadata':{'source':'hermes.sync_turn'}},{'id':'two','metadata':{'source':'hermes.memory_write.add'}},{'id':'three','content':'same text without reliable source'}]))
            report=rollout.inspect_legacy_export(path)
            self.assertEqual(report['known_raw_excerpts'],1)
            self.assertEqual(report['known_native_mirrors'],1)
            self.assertEqual(report['ambiguous_or_unrelated'],1)
            self.assertFalse(report['originals_reconstructed'])
            self.assertFalse(report['automatic_historical_changes'])

    def test_review_pages_preserve_actual_ids_sessions_and_relationships(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'legacy.json'
            rows=[{'id':'one','session_id':'s1','parent_session_id':'parent','derived_from_ids':['evidence-1'],
                   'metadata':{'source':'hermes.sync_turn','observation_id':'obs-1'}},
                  {'id':'two','metadata':{'source':'hermes.memory_write.add','session_id':'s2','entry_id':'reported-entry'}},
                  {'id':'three','metadata':{'source':'unrelated'}}]
            path.write_text(json.dumps(rows))
            raw=path.read_bytes()
            first=rollout.inspect_legacy_export(path,page_size=1)
            self.assertEqual(first['total_records'],3)
            self.assertEqual(first['records'][0]['record_id'],'one')
            self.assertEqual(first['records'][0]['provenance']['record']['session_id'],'s1')
            self.assertEqual(first['records'][0]['provenance']['record']['parent_session_id'],'parent')
            self.assertEqual(first['records'][0]['provenance']['record']['derived_from_ids'],['evidence-1'])
            self.assertEqual(first['records'][0]['provenance']['metadata']['observation_id'],'obs-1')
            self.assertEqual(first['records'][0]['evidence']['coverage'],'legacy_bounded_excerpt')
            self.assertEqual(first['records'][0]['evidence']['truncated'],'unknown')
            self.assertIsNone(first['records'][0]['evidence']['original_length'])
            self.assertIsNone(first['records'][0]['evidence']['original_sha256'])
            self.assertFalse(first['records'][0]['evidence']['original_reconstructed'])
            second=rollout.inspect_legacy_export(path,page_size=1,cursor=first['next_cursor'])
            self.assertEqual(second['records'][0]['record_id'],'two')
            self.assertEqual(second['records'][0]['provenance']['metadata']['entry_id'],'reported-entry')
            self.assertTrue(second['records'][0]['native_identity_ambiguous'])
            self.assertTrue(second['records'][0]['profile_ambiguous'])
            third=rollout.inspect_legacy_export(path,page_size=1,cursor=second['next_cursor'])
            self.assertEqual(third['records'][0]['record_id'],'three')
            self.assertIsNone(third['next_cursor'])
            self.assertEqual(raw,path.read_bytes())
            self.assertEqual(first['export_fingerprint'],third['export_fingerprint'])

    def test_resume_refuses_changed_export_invalid_cursor_or_page_bound(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'legacy.json';path.write_text(json.dumps([{},{}]))
            first=rollout.inspect_legacy_export(path,page_size=1)
            path.write_text(json.dumps([{}, {'id':'changed'}]))
            with self.assertRaisesRegex(ValueError,'legacy_cursor_export_mismatch'):
                rollout.inspect_legacy_export(path,page_size=1,cursor=first['next_cursor'])
            for cursor in ('not-json','a'*4097):
                with self.assertRaisesRegex(ValueError,'legacy_cursor_invalid'):
                    rollout.inspect_legacy_export(path,cursor=cursor)
            for size in (0,101,True):
                with self.assertRaisesRegex(ValueError,'legacy_page_size_invalid'):
                    rollout.inspect_legacy_export(path,page_size=size)

    def test_review_keeps_conflicting_provenance_and_does_not_leak_content(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'legacy.json'
            path.write_text(json.dumps([{'id':'one','session_id':'actual-top','content':'private-content',
                'metadata':{'session_id':'actual-metadata','source':'hermes.sync_turn','token':'private-token',
                            'completeness':{'truncated':True,'original_length':1234,'original_sha256':'a'*64}}},
                {'content':'unknown','metadata':{'source':'hermes.memory_write.update'}}]))
            report=rollout.inspect_legacy_export(path)
            row=report['records'][0]
            self.assertEqual(row['provenance']['record']['session_id'],'actual-top')
            self.assertEqual(row['provenance']['metadata']['session_id'],'actual-metadata')
            self.assertIn('session_id_conflict',row['ambiguities'])
            self.assertEqual(row['evidence']['original_length'],1234)
            self.assertEqual(row['evidence']['original_sha256'],'a'*64)
            self.assertTrue(row['evidence']['truncated'])
            self.assertIsNone(report['records'][1]['record_id'])
            self.assertIn('missing_record_id',report['records'][1]['ambiguities'])
            self.assertNotIn('private-content',json.dumps(report))
            self.assertNotIn('private-token',json.dumps(report))

    def test_malformed_source_and_oversized_relationships_stay_ambiguous(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'legacy.json'
            path.write_text(json.dumps([{'id':'one','metadata':{'source':{'unexpected':'object'}}},
                {'id':'two','derived_from_ids':['e'+str(i) for i in range(101)],'metadata':{'source':'hermes.memory_write.add'}}]))
            report=rollout.inspect_legacy_export(path)
            self.assertEqual(report['records'][0]['classification'],'ambiguous_or_unrelated')
            self.assertIn('record.derived_from_ids_invalid_or_over_limit',report['records'][1]['ambiguities'])
            self.assertNotIn('derived_from_ids',report['records'][1]['provenance']['record'])
