"""Run the packaged provider against a real host; canonical settlement is required.

Use the Hermes Python interpreter so its public egress scrub API is available.
All native writes and journal files are confined to a fresh temporary profile.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import uuid


def contains_record(result, content):
    assert isinstance(result, dict) and result.get('success') is not False and not result.get('error'), 'memory read failed'
    assert isinstance(result.get('results'), list), 'invalid memory results'
    assert isinstance(result.get('provisional_results', []), list), 'invalid provisional results'
    return any(row.get('content') == content for group in ('results','provisional_results') for row in result.get(group,[]) if isinstance(row,dict))


def validate_scope_rejection(result):
    assert (isinstance(result,dict) and result.get('success') is False and result.get('http_status')==400 and result.get('error') in {'invalid_scope','unknown_scope','invalid_arguments','invalid_request','partition_mismatch'}), 'scope override was not rejected by authorization'


def load_provider():
    name='backplane_memory_smoke_'+uuid.uuid4().hex
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name('__init__.py'))
    plugin=importlib.util.module_from_spec(spec)
    sys.modules[name]=plugin
    spec.loader.exec_module(plugin)
    return plugin.BackplaneMemoryProvider()


def run(base_url, agent_id, cwd, hermes_home=None, timeout=30):
    root=Path(hermes_home).expanduser() if hermes_home else None
    if root:
        root.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='backplane-hermes-smoke-',dir=root) as temp:
        home=Path(temp)
        native=home/'memories';native.mkdir()
        memory=native/'MEMORY.md';user=native/'USER.md'
        memory.write_text('');user.write_text('')
        (home/'backplane-memory.json').write_text(json.dumps({'url':base_url,'agent_id':agent_id}))
        provider=load_provider()
        session='smoke-'+uuid.uuid4().hex
        provider.initialize(session,hermes_home=str(home),cwd=cwd)
        marker='bpherme'+uuid.uuid4().hex
        original='Native source smoke '+marker
        corrected='Corrected native source smoke '+marker
        explicit_id=None
        def settle():
            status=provider.flush(timeout=timeout,canonical=True)
            assert status['success'], 'canonical delivery did not settle: '+json.dumps(status)
            return status
        def listed():
            value=json.loads(provider.handle_tool_call('memory_list',{'limit':100}))
            assert value.get('success') is not False and isinstance(value.get('results'),list), 'canonical list failed'
            return value
        try:
            assert provider.is_available(), 'invalid local provider configuration'
            assert provider.delivery_status()['native_egress']=='available', 'native_egress_scrub_unavailable: run with the Hermes interpreter'
            settle()
            memory.write_text(original)
            provider.on_memory_write('add','memory',original,metadata={'session_id':session,'tool_call_id':'shared'})
            user.write_text(original)
            provider.on_memory_write('add','user',original,metadata={'session_id':session,'tool_call_id':'shared'})
            settle()
            assert contains_record(listed(),original), 'native source readback missing'
            original_id=next(row['id'] for row in listed()['results'] if row.get('content')==original)
            memory.write_text(corrected)
            provider.on_memory_write('replace','memory',corrected,metadata={'previous_content':original,'session_id':session,'tool_call_id':'shared'})
            settle()
            assert contains_record(listed(),corrected), 'corrected source missing'
            assert contains_record(listed(),original), 'independent user source was withdrawn'
            messages=[{'role':'user','content':'My preferred time is sunrise. '+marker,'message_uid':str(uuid.uuid4())},{'role':'assistant','content':'I guessed sunset.','message_uid':str(uuid.uuid4())},{'role':'user','content':'Correction: sunrise.','message_uid':str(uuid.uuid4())}]
            provider.sync_turn(messages[0]['content'],messages[1]['content'],session_id=session,messages=messages)
            before=json.dumps(messages,sort_keys=True)
            checkpoint=provider.on_pre_compress(messages,require_checkpoint=True)
            assert before==json.dumps(messages,sort_keys=True), 'checkpoint mutated transcript'
            assert 'Evidence event references:' in checkpoint, 'checkpoint references missing'
            settle()
            memory.write_text('')
            provider.on_memory_write('remove','memory','',metadata={'previous_content':corrected,'session_id':session})
            settle()
            assert not contains_record(listed(),corrected), 'withdrawn sole source remained current'
            assert contains_record(listed(),original), 'independent source was lost'
            forgotten=json.loads(provider.handle_tool_call('memory_forget',{'id':original_id}))
            assert forgotten.get('success') is not False and not forgotten.get('error'), 'global forget failed'
            provider.reconcile_sources(dry_run=False)
            settle()
            assert not contains_record(listed(),original), 'reconciliation undid global forget'
            saved=json.loads(provider.handle_tool_call('memory_save',{'content':'Explicit tool smoke '+marker,'tags':[marker]}))
            assert saved.get('id'), 'generic memory_save failed'
            explicit_id=saved['id']
            validate_scope_rejection(json.loads(provider.handle_tool_call('memory_list',{'scope':cwd})))
            assert marker not in provider.system_prompt_block(), 'system prompt contains dynamic memory'
            user.write_text('')
            provider.on_memory_write('remove','user','',metadata={'previous_content':original,'session_id':session})
            provider.on_session_end(messages)
            status=settle()
            return {'native_lifecycle':True,'independent_source':True,'global_forget':True,'capture_canonical':True,'derived_extraction_verified':False,'checkpoint':True,'scope_rejected':True,'delivery':status}
        finally:
            if explicit_id:
                result=json.loads(provider.handle_tool_call('memory_forget',{'id':explicit_id}))
                assert result.get('success') is not False and not result.get('error'), 'generic cleanup failed'
            provider.shutdown()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url',default='http://127.0.0.1:4222')
    parser.add_argument('--agent-id',default='hermes')
    parser.add_argument('--cwd',default='/tmp/backplane-hermes-smoke')
    parser.add_argument('--hermes-home',help='Parent for a new dedicated temporary test profile')
    parser.add_argument('--timeout',type=float,default=30)
    args=parser.parse_args()
    print(json.dumps(run(args.base_url,args.agent_id,args.cwd,args.hermes_home,args.timeout)))
