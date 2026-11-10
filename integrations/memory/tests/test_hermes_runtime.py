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


def search_result(*contents):
    return {"results":[{"id":"memory-"+str(index),"kind":"fact","content":content,"status":"active","observed_at":"2026-11-09T00:00:00Z","provenance":{"host":"host-a","agent":"codex"}} for index,content in enumerate(contents)]}


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
            status,body=body if isinstance(body,tuple) else (200,body)
            encoded=json.dumps(body).encode()
            self.send_response(status)
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
        self.provider=self.build()

    def build(self, **kwargs):
        provider=plugin.BackplaneMemoryProvider()
        with patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True):
            provider.initialize('session-1',hermes_home=str(self.home),**kwargs)
        self.addCleanup(provider.shutdown)
        return provider

    def test_setup_values_are_loaded_and_profile_instances_do_not_share_state(self):
        other=self.home/'other'
        self.provider.save_config({'agent_id':'other-agent','context_token_budget':256},str(other))
        second=plugin.BackplaneMemoryProvider()
        with patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True):
            second.initialize('same-session',hermes_home=str(other),agent_identity='second')
        self.addCleanup(second.shutdown)
        self.assertEqual(second._agent_id,'other-agent')
        self.assertEqual(second._config['context_token_budget'],256)
        self.assertNotEqual(second._journal.installation_id,self.provider._journal.installation_id)
        self.assertNotEqual(second._journal.path,self.provider._journal.path)
        self.assertEqual(self.provider._config['context_token_budget'],1200)
        self.assertEqual(self.provider._config['search_limit'],8)

    def test_config_from_the_retired_setup_is_ignored_with_a_warning(self):
        home=self.home/'legacy'
        home.mkdir()
        (home/'backplane-memory.json').write_text(json.dumps({'agent_id':'legacy-agent','retired_selector':'74be1bcf-a924-4fb4-9a3a-8cddf8d857b7','relevance_mode':'lexical'}))
        provider=plugin.BackplaneMemoryProvider()
        with patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True),self.assertLogs(plugin.logger,level='WARNING') as logs:
            provider.initialize('s',hermes_home=str(home))
        self.addCleanup(provider.shutdown)
        self.assertEqual(provider._agent_id,'legacy-agent')
        self.assertNotIn('74be1bcf','\n'.join(logs.output))
        provider.save_config({'context_token_budget':300},str(home))
        self.assertEqual(json.loads((home/'backplane-memory.json').read_text()),{'agent_id':'legacy-agent','context_token_budget':300})
        with self.assertRaisesRegex(ValueError,'invalid_provider_config'):
            provider.save_config({'unknown':1},str(home))

    def test_invalid_config_values_make_the_provider_unavailable(self):
        for config in ({'url':'ftp://host'},{'url':'http://user:pw@127.0.0.1:4222'},{'search_limit':0},{'agent_id':' '}):
            with self.subTest(config=config):
                home=self.home/('bad-'+str(abs(hash(json.dumps(config)))))
                home.mkdir()
                (home/'backplane-memory.json').write_text(json.dumps(config))
                provider=plugin.BackplaneMemoryProvider()
                provider._home=home
                with patch.dict(plugin.os.environ,{},clear=True):
                    self.assertFalse(provider.is_available())

    def test_plaintext_remote_transport_is_warned(self):
        home=self.home/'remote'
        home.mkdir()
        (home/'backplane-memory.json').write_text(json.dumps({'url':'http://memory.example.com:4222'}))
        provider=plugin.BackplaneMemoryProvider()
        with patch.object(plugin.BackplaneMemoryProvider,'_start_worker',lambda s:None),patch.dict(plugin.os.environ,{},clear=True),self.assertLogs(plugin.logger,level='WARNING') as logs:
            provider.initialize('s',hermes_home=str(home))
        self.addCleanup(provider.shutdown)
        self.assertIn('plaintext_remote_transport','\n'.join(logs.output))

    def test_real_http_gateway_unavailable_yields_no_context(self):
        def dispatch(path,payload,raw):
            return (503,{'ok':False,'error':'gateway_unavailable'})
        self.provider.shutdown()
        with http_fixture(dispatch) as base:
            self.home=self.home/'http-503';self.home.mkdir()
            (self.home/'backplane-memory.json').write_text(json.dumps({'url':base}))
            provider=self.build()
            with self.assertLogs(plugin.logger,level='WARNING') as logs:
                self.assertEqual(provider.prefetch('anything'),'')
            self.assertEqual(len(logs.records),1)
            self.assertIn('503','\n'.join(logs.output))

    def test_real_http_search_renders_context(self):
        def dispatch(path,payload,raw):
            self.assertEqual(path,'/memory/hermes/call/search')
            return search_result('alpha fact')
        self.provider.shutdown()
        with http_fixture(lambda path,payload,raw:{'ok':True,'result':dispatch(path,payload,raw)}) as base:
            self.home=self.home/'http-ok';self.home.mkdir()
            (self.home/'backplane-memory.json').write_text(json.dumps({'url':base}))
            provider=self.build()
            self.assertIn('alpha fact',provider.prefetch('alpha'))

    def test_lost_http_ack_replays_identical_payload_after_restart(self):
        accepted={}; attempts={}; bodies=[]
        def dispatch(path,payload,raw):
            if path=='/capture/v1/status':
                return {'ok':True,'result':{'protocol':'hermes_capture.v1','items':[{'event_id':event,'status':'canonical_committed'} for event in payload['event_ids']]}}
            event=payload['event_id'];bodies.append((event,raw))
            if event in accepted:
                self.assertEqual(accepted[event],raw)
            accepted[event]=raw;attempts[event]=attempts.get(event,0)+1
            if path.startswith('/capture/') and attempts[event]==1:
                return None
            return {'ok':True,'status':'duplicate','event_id':event}
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
