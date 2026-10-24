import ast
from contextlib import contextmanager
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import inspect
import json
from pathlib import Path
import socket
import tempfile
import textwrap
import threading
import time
from types import SimpleNamespace
from typing import Any, Callable, Optional
import unittest
from unittest.mock import patch

from test_hermes_delivery import load_plugin

plugin = load_plugin()


def load_pinned_scrubber():
    """Exact upstream redactor with only scoped vault-home/file-name dependencies stubbed."""
    import sys
    import types
    fixture=json.loads((Path(__file__).parent/'fixtures'/'hermes_contract.json').read_text())
    source=next(item for item in fixture['sources'] if item['path']=='agent/redact.py')
    raw=source['snippets'][0]['source']
    assert hashlib.sha256(raw.encode()).hexdigest()==source['sha256']
    fs=types.ModuleType('agent.file_safety')
    fs._BLOCKED_PROJECT_ENV_BASENAMES=frozenset({'.env'})
    hc=types.ModuleType('hermes_constants')
    hc.get_hermes_home=lambda:Path('/nonexistent-pinned-hermes-test-profile')
    ns={'__name__':'pinned_hermes_redactor_fixture'}
    with patch.dict(sys.modules,{'agent.file_safety':fs,'hermes_constants':hc}):
        exec(raw,ns)
    # Keep the helper's profile lookup pure after dependency stubs leave scope.
    ns['_vault_scope']=lambda:'/nonexistent-pinned-hermes-test-profile'
    return ns['redact_for_egress']


def capability():
    binding={"access_id":"fixture-access","authority_version":1,"partition":{"memory_space_id":"space","scope":"fixture","namespace":"default"}}
    fingerprint=hashlib.sha256(plugin.canonical_json(binding).encode()).hexdigest()
    return {"protocol":"memory_sources.v1","supported":True,"ready":True,"capture_ready":True,"contracts":["memory_sources.v1","hermes_capture.v1"],"negotiated":["memory_sources.v1","hermes_capture.v1"],"binding":binding,"binding_fingerprint":fingerprint,"capture_binding":binding,"capture_binding_fingerprint":fingerprint}


def current(content="alpha fact", **kwargs):
    return {"id":"memory-1","canonical_id":"memory-1","revision":1,"content":content,"policy_version":"current_context.v1","lifecycle_state":"active","effective_support":True,"support_complete":True,"source_refs":[],"trust":"established_fact","expires_at":None,"valid_until":None,**kwargs}


@contextmanager
def http_fixture(dispatch):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            raw=self.rfile.read(int(self.headers['Content-Length']))
            body=dispatch(self.path,json.loads(raw),raw)
            if body is None:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            encoded=json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        def log_message(self,*args): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads=True
    worker=threading.Thread(target=server.serve_forever,daemon=True)
    worker.start()
    try:
        yield 'http://127.0.0.1:'+str(server.server_port)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        assert not worker.is_alive()


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name)
        (self.home/'memories').mkdir()
        for target in ('MEMORY.md','USER.md'):
            (self.home/'memories'/target).write_text('')
        self.provider=self.build()

    def build(self, **kwargs):
        provider=plugin.BackplaneMemoryProvider()
        with patch.object(plugin,'_load_egress_scrubber',return_value=lambda text:text),patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True):
            provider.initialize('session-1',hermes_home=str(self.home),**kwargs)
        self.addCleanup(provider.shutdown)
        return provider

    def test_setup_values_are_loaded_and_profile_instances_do_not_share_state(self):
        other=self.home/'other'
        self.provider.save_config({'agent_id':'other-agent','context_token_budget':256},str(other))
        second=plugin.BackplaneMemoryProvider()
        with patch.object(plugin,'_load_egress_scrubber',return_value=lambda text:text),patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True):
            second.initialize('same-session',hermes_home=str(other),agent_identity='second')
        self.addCleanup(second.shutdown)
        self.assertEqual(second._agent_id,'other-agent')
        self.assertEqual(second._config['context_token_budget'],256)
        self.assertNotEqual(second._source('memory'),self.provider._source('memory'))
        self.assertNotEqual(second._journal.path,self.provider._journal.path)
        self.assertEqual(self.provider._config['context_token_budget'],1200)

    def test_prefetch_consumes_cache_without_network_and_invalidates_on_change(self):
        self.provider.queue_prefetch('alpha')
        key,value=self.provider._prefetch_jobs.popitem(last=False)
        with patch.object(plugin,'_post',return_value={'ok':True,'result':{'results':[current()]}}) as post:
            self.provider._fetch_context(key,value)
            self.assertIn('alpha fact',self.provider.prefetch('alpha'))
            self.assertEqual(post.call_count,1)
        (self.home/'memories'/'MEMORY.md').write_text('corrected alpha fact')
        self.provider.on_memory_write('add','memory','corrected alpha fact')
        with patch.object(plugin,'_post',side_effect=AssertionError('prefetch must not block')):
            self.assertEqual(self.provider.prefetch('alpha'),'')

    def test_context_trust_lifecycle_relevance_and_final_budget(self):
        from importlib import import_module
        render=import_module(plugin.__name__+'.context').render_context
        self.provider._config['context_token_budget']=180
        rows=[current('alpha '+('x'*1000),canonical_id='oversized'),current('alpha assistant guess',canonical_id='guess',trust='candidate_inference'),current('alpha raw statement',canonical_id='raw',trust='raw_evidence'),current('alpha obsolete',canonical_id='old',lifecycle_state='superseded'),current('alpha expired',canonical_id='expired',expires_at='2000-01-01T00:00:00Z'),current('unrelated banana',canonical_id='unrelated')]
        text,ttl=render(self.provider,'alpha',{'results':rows})
        self.assertIn('candidate inference',text)
        self.assertIn('alpha assistant guess',text)
        self.assertNotIn('established fact',text)
        self.assertNotIn('raw statement',text)
        self.assertNotIn('obsolete',text)
        self.assertNotIn('expired',text)
        self.assertNotIn('banana',text)
        self.assertNotIn('xxx',text)
        self.assertLessEqual(len(text.encode()),180)
        self.assertEqual(render(self.provider,'zebra',{'results':rows})[0],'')

    def test_complete_independent_support_survives_local_withdrawal(self):
        from importlib import import_module
        render=import_module(plugin.__name__+'.context').render_context
        path=self.home/'memories'/'MEMORY.md'
        path.write_text('alpha fact')
        self.provider.on_memory_write('add','memory','alpha fact')
        entry=dict(self.provider._journal.db.execute("SELECT * FROM source_entries WHERE target='memory'").fetchone())
        ref={'source':self.provider._source('memory'),'entry_id':entry['entry_id'],'source_revision':entry['revision'],'event_id':'e','active':True}
        path.write_text('')
        self.provider.on_memory_write('remove','memory','',metadata={'previous_content':'alpha fact'})
        self.assertEqual(render(self.provider,'alpha',{'results':[current(source_refs=[ref])]})[0],'')
        independent={**ref,'source':{**ref['source'],'profile_id':'independent'},'entry_id':'independent-entry'}
        self.assertIn('alpha fact',render(self.provider,'alpha',{'results':[current(source_refs=[ref,independent])]})[0])

    def test_unknown_policy_stale_and_incomplete_support_cannot_enter_cache(self):
        from importlib import import_module
        render=import_module(plugin.__name__+'.context').render_context
        for result in [{'results':[current(policy_version='legacy')]},{'results':[current(support_complete=False)]},{'results':[current()],'stale':True}]:
            self.assertEqual(render(self.provider,'alpha',result)[0],'')

    def test_peer_without_new_contract_never_emulates_native_write(self):
        with patch.object(plugin,'_post',return_value={'ok':False,'error':'not_found','http_status':404}) as post,patch.object(plugin,'_http') as http:
            self.assertFalse(self.provider._deliver_once())
            self.assertEqual(post.call_args.args[2],'source_capabilities')
            http.assert_not_called()
        self.assertGreater(self.provider.delivery_status()['local_pending'],0)

    def test_capture_contract_must_be_negotiated_before_automatic_delivery(self):
        caps=capability();caps['negotiated']=['memory_sources.v1']
        paths=[]
        def source_only(base,path,payload):
            paths.append(path)
            return {'ok':True,'result':{'protocol':'memory_sources.v1','event_id':payload['event_id'],'status':'committed'}}
        with patch.object(plugin,'_post',return_value={'ok':True,'result':caps}),patch.object(plugin,'_http',side_effect=source_only):
            self.provider._deliver_once()
        self.assertFalse(any(path.startswith('/capture/') for path in paths))
        self.assertGreater(self.provider.delivery_status()['capture_deferred'],0)
        with self.assertRaisesRegex(RuntimeError,'capture_unavailable'):
            self.provider.on_pre_compress([{'role':'user','content':'evidence','message_uid':'u1'}],require_checkpoint=True)

    def test_capture_binding_mismatch_refuses_checkpoint_while_sources_can_settle(self):
        caps=capability();caps['capture_ready']=False;caps['capture_error']='capture_binding_mismatch'
        with patch.object(plugin,'_post',return_value={'ok':True,'result':caps}):
            self.assertTrue(self.provider._check_peer())
        with self.assertRaisesRegex(RuntimeError,'capture_binding_mismatch'):
            self.provider.on_pre_compress([{'role':'user','content':'evidence','message_uid':'u1'}],require_checkpoint=True)
        self.assertEqual(self.provider.delivery_status()['capture_binding'],'capture_binding_mismatch')

    def test_changed_binding_is_terminal_and_cannot_auto_rebind_after_restart(self):
        caps=capability()
        with patch.object(plugin,'_post',return_value={'ok':True,'result':caps}):
            self.assertTrue(self.provider._check_peer())
        other=copy.deepcopy(caps);other['binding']['authority_version']=2
        other['binding_fingerprint']=hashlib.sha256(plugin.canonical_json(other['binding']).encode()).hexdigest()
        self.provider._peer_checked=0
        with patch.object(plugin,'_post',return_value={'ok':True,'result':other}):
            self.assertFalse(self.provider._check_peer())
        self.assertGreater(self.provider.delivery_status()['rejected'],0)
        self.provider.shutdown()
        second=self.build()
        with patch.object(plugin,'_post',side_effect=AssertionError('blocked binding cannot auto rebind')):
            self.assertFalse(second._check_peer())

    def test_lost_http_ack_replays_identical_payload_after_restart(self):
        accepted={}; attempts={}; bodies=[]
        def dispatch(path,payload,raw):
            if path.endswith('source_capabilities'):
                return {'ok':True,'result':capability()}
            if path=='/capture/v1/status':
                return {'ok':True,'result':{'protocol':'hermes_capture.v1','items':[{'event_id':event,'status':'canonical_committed'} for event in payload['event_ids']]}}
            event=payload['event_id'];bodies.append((event,raw))
            if event in accepted:
                self.assertEqual(accepted[event],raw)
            accepted[event]=raw;attempts[event]=attempts.get(event,0)+1
            if path.startswith('/capture/') and attempts[event]==1:
                return None
            if path.startswith('/capture/'):
                return {'ok':True,'status':'duplicate','event_id':event}
            return {'ok':True,'result':{'protocol':'memory_sources.v1','event_id':event,'status':'committed','outcome':'applied','authority':'canonical','consistency':'canonical'}}
        self.provider.shutdown()
        with http_fixture(dispatch) as base:
            # Fresh bound profile to avoid rewriting the existing immutable URL binding.
            self.home=self.home/'http-profile';self.home.mkdir()
            (self.home/'backplane-memory.json').write_text(json.dumps({'url':base}))
            first=self.build()
            with patch('sys.stderr',new_callable=__import__('io').StringIO):
                first._deliver_once()
            first.shutdown()
            second=self.build()
            second._journal.db.execute('UPDATE delivery SET next_at=0')
            for _ in range(4):
                second._deliver_once()
                second._journal.db.execute('UPDATE delivery SET next_at=0')
                if not second._journal.status()['local_pending'] and not second._journal.status()['host_accepted']:
                    break
            self.assertEqual(second._journal.status()['local_pending'],0)
            self.assertEqual(second._journal.status()['host_accepted'],0)
            self.assertGreater(second._journal.status()['canonical_committed'],0)
            event=bodies[0][0]
            self.assertEqual(attempts[event],2)


class PinnedHermesContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture=json.loads((Path(__file__).parent/'fixtures'/'hermes_contract.json').read_text())
        cls.snippets={snippet['name']:snippet['source'] for source in cls.fixture['sources'] for snippet in source['snippets']}

    def test_exact_upstream_provider_signatures_are_implemented(self):
        self.assertEqual(self.fixture['commit'],'bac34e9e9946c9c6a9ce7ce64efadd47f8fa375b')
        original=next(source for source in self.fixture['sources'] if source['path']=='agent/memory_provider.py')
        raw=original['snippets'][0]['source']
        self.assertEqual(hashlib.sha256(raw.encode()).hexdigest(),original['sha256'])
        cls=next(node for node in ast.parse(raw).body if isinstance(node,ast.ClassDef) and node.name=='MemoryProvider')
        for name in ('initialize','sync_turn','on_memory_write','on_session_switch','on_pre_compress'):
            method=next(node for node in cls.body if isinstance(node,ast.FunctionDef) and node.name==name)
            implemented=inspect.signature(getattr(plugin.BackplaneMemoryProvider,name))
            self.assertTrue(all(arg.arg in implemented.parameters for arg in method.args.args+method.args.kwonlyargs),name)

    def test_native_redactor_uses_admitted_public_reexport_and_exact_egress_behavior(self):
        raw=self.snippets['hermes_cli/plugin_validate_private_imports.py']
        tree=ast.parse(raw)
        assignment=next(node for node in tree.body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='_PUBLIC' for t in node.targets))
        scope={}
        exec(compile(ast.Module(body=[assignment],type_ignores=[]),'pinned-public-imports','exec'),scope)
        self.assertIn('agent.memory_manager',scope['_PUBLIC'])
        scrub=load_pinned_scrubber()
        self.assertNotIn('synthetic-private-secret-value',scrub('API_KEY=synthetic-private-secret-value'))
        self.assertNotIn('1234567890123456789012345',scrub('Bearer 1234567890123456789012345'))
        self.assertEqual(scrub('ordinary harmless fact'),'ordinary harmless fact')

    def test_exact_upstream_checkpoint_normalizer_preserves_real_occurrences(self):
        fake=type(__import__('sys'))('agent.context_compressor');fake.COMPRESSED_SUMMARY_METADATA_KEY='_compressed_summary'
        scope={'Any':Any}
        with patch.dict(__import__('sys').modules,{'agent.context_compressor':fake}):
            exec(self.snippets['_direct_messages_for_pre_compress_memory'],scope)
            rows=[{'role':'user','content':'same','message_uid':'u1'},{'role':'user','content':'same','message_uid':'u2'},{'role':'assistant','content':'prose','tool_calls':[{'id':'repeat'}],'_tool_call_uids':{'repeat':'occ1'}},{'role':'assistant','content':'summary','_compressed_summary':True},{'role':'tool','content':'result'}]
            before=copy.deepcopy(rows);out=scope['_direct_messages_for_pre_compress_memory'](rows)
        self.assertEqual(len(out),3)
        self.assertEqual([r.get('message_uid') for r in out[:2]],['u1','u2'])
        self.assertNotIn('tool_calls',out[2]);self.assertEqual(out[2]['_tool_call_uids'],{'repeat':'occ1'})
        self.assertEqual(rows,before)

    def test_exact_upstream_batch_callback_uses_complete_patch_and_shared_tool_id(self):
        source='class Manager:\n'+textwrap.indent(textwrap.dedent(self.snippets['_memory_tool_result_succeeded']),'    ')+textwrap.indent(textwrap.dedent(self.snippets['notify_memory_tool_write']),'    ')
        scope={'Any':Any,'Optional':Optional,'Callable':Callable,'json':json,'logger':SimpleNamespace(debug=lambda *a:None)}
        exec(source,scope);manager=scope['Manager']();manager._MIRRORED_MEMORY_ACTIONS={'add','replace','patch','remove'}
        calls=[];manager.on_memory_write=lambda *a,**k:calls.append((a,k))
        manager.notify_memory_tool_write({'success':True,'patched_entries':{'2':'old'},'patched_entries_after':{'2':'new'},'removed_entries':{'3':'new'}},{'target':'memory','operations':[{'action':'add','content':'old'},{'action':'patch','old_text':'old','content':'new'},{'action':'remove','old_text':'new'}]},build_metadata=lambda:{'session_id':'s1','tool_call_id':'shared'})
        self.assertEqual([a[0] for a,k in calls],['add','replace','remove'])
        self.assertEqual(calls[1][0][2],'new');self.assertEqual(calls[1][1]['metadata']['previous_content'],'old')
        self.assertEqual(calls[2][1]['metadata']['previous_content'],'new')
        self.assertTrue(all(k['metadata']['tool_call_id']=='shared' for a,k in calls))
        self.assertFalse(any('index' in key for a,k in calls for key in k['metadata']))
