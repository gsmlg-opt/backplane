"""Bounded, resumable native-source rollout. Default is a content-free dry run.

Legacy exports are classified for review; no historical record is deleted/relabelled
or assigned an invented native entry identity. Apply uses the existing durable journal.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid


def load_plugin():
    name='backplane_memory_rollout_'+uuid.uuid4().hex
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name('__init__.py'))
    module=importlib.util.module_from_spec(spec)
    sys.modules[name]=module
    spec.loader.exec_module(module)
    return module


def inspect_profile(hermes_home):
    home=Path(hermes_home).expanduser().resolve()
    plugin=load_plugin()
    journal=home/'backplane-memory'/'delivery.sqlite3'
    connection=sqlite3.connect(journal.as_uri()+'?mode=ro',uri=True) if journal.exists() else None
    report=[]
    try:
        for target in ('memory','user'):
            try:
                with plugin.source.source_snapshot(home,target) as entries:
                    known={row[0] for row in connection.execute('SELECT content FROM source_entries WHERE target=? AND active=1',(target,))} if connection else set()
                    report.append({'target':target,'complete':True,'entries':len(entries),'new_or_ambiguous_entries':len(set(entries)-known),'absent_known_entries':len(known-set(entries))})
            except (OSError,UnicodeError):
                report.append({'target':target,'complete':False,'error':'source_snapshot_unavailable','withdrawals_authorized':False})
    finally:
        if connection:
            connection.close()
    return {'dry_run':True,'native_sources':report,'legacy_reassignment':False}


_PROVENANCE_IDS = ('id','memory_id','observation_id','observation_ids','session_id',
                   'parent_session_id','message_uid','tool_call_uid','tool_call_id',
                   'entry_id','event_id','source_event_id','source_observation_id',
                   'derived_from_ids','parent_memory_id','supersedes_id','superseded_by_id',
                   'installation_id','profile_id','agent_id','host_id','target')


def _safe_identifier(value):
    return isinstance(value,str) and 0<len(value)<=512 and not any(ord(c)<32 or ord(c)==127 for c in value)


def _legacy_record(row,index):
    row=row if isinstance(row,dict) else {}
    metadata=row.get('metadata') if isinstance(row.get('metadata'),dict) else {}
    source=metadata.get('source')
    source=source if isinstance(source,str) else None
    kind='known_raw_excerpt' if source=='hermes.sync_turn' else 'known_native_mirror' if source in {'hermes.memory_write.add','hermes.memory_write.update'} else 'ambiguous_or_unrelated'
    ambiguities=[]
    provenance={}
    for origin,values in (('record',row),('metadata',metadata)):
        fields={}
        for key in _PROVENANCE_IDS:
            if key not in values:
                continue
            value=values[key]
            if _safe_identifier(value):
                fields[key]=value
            elif isinstance(value,list) and len(value)<=100 and all(_safe_identifier(v) for v in value):
                fields[key]=value
            else:
                ambiguities.append(origin+'.'+key+'_invalid_or_over_limit')
        provenance[origin]=fields
    record_id=row.get('id') if _safe_identifier(row.get('id')) else None
    if record_id is None:
        ambiguities.append('missing_record_id')
    for key in ('session_id','parent_session_id','installation_id','profile_id','target'):
        if key in provenance['record'] and key in provenance['metadata'] and provenance['record'][key]!=provenance['metadata'][key]:
            ambiguities.append(key+'_conflict')
    if kind=='ambiguous_or_unrelated':
        ambiguities.append('source_unrecognized_or_missing')
    # Old content-only files cannot prove a canonical/native identity mapping.
    native_ambiguous=kind=='known_native_mirror'
    if native_ambiguous:
        ambiguities.append('native_entry_mapping_unproven')
    profile_ambiguous=any(not any(_safe_identifier(values.get(key)) for values in (row,metadata)) for key in ('installation_id','profile_id','target')) or any(k+'_conflict' in ambiguities for k in ('installation_id','profile_id','target'))
    if profile_ambiguous:
        ambiguities.append('profile_binding_unproven')
    review={'export_index':index,'record_id':record_id,'classification':kind,
            'source':source if _safe_identifier(source) else None,'provenance':provenance,
            'native_identity_ambiguous':native_ambiguous,'profile_ambiguous':profile_ambiguous,
            'ambiguities':ambiguities,'automatic_action':'preserve',
            'review_action':'review_excerpt_provenance' if kind=='known_raw_excerpt' else 'review_native_mirror_mapping' if native_ambiguous else 'preserve_ambiguous_or_unrelated'}
    if kind=='known_raw_excerpt':
        completeness=metadata.get('completeness') if isinstance(metadata.get('completeness'),dict) else row.get('completeness',{})
        completeness=completeness if isinstance(completeness,dict) else {}
        length=completeness.get('original_length')
        digest=completeness.get('original_sha256')
        review['evidence']={'coverage':'legacy_bounded_excerpt',
            'truncated':completeness.get('truncated') if type(completeness.get('truncated')) is bool else 'unknown',
            'original_length':length if type(length) is int and length>=0 else None,
            'original_sha256':digest if isinstance(digest,str) and len(digest)==64 and all(c in '0123456789abcdef' for c in digest) else None,
            'original_reconstructed':False,'original_locator_inferred':False}
    return review


def _review_cursor(fingerprint,offset):
    return base64.urlsafe_b64encode(json.dumps({'version':1,'export_fingerprint':fingerprint,'offset':offset},sort_keys=True,separators=(',',':')).encode()).decode()


def inspect_legacy_export(path, *, page_size=50, cursor=None):
    if type(page_size) is not int or not 1<=page_size<=100:
        raise ValueError('legacy_page_size_invalid')
    with Path(path).open('rb') as stream:
        raw=stream.read(2*1024*1024+1)
    if len(raw)>2*1024*1024:
        raise ValueError('legacy_export_too_large')
    rows=json.loads(raw)
    if isinstance(rows,dict):
        rows=rows.get('results')
    if not isinstance(rows,list) or len(rows)>1000:
        raise ValueError('legacy_export_invalid')
    fingerprint=hashlib.sha256(raw).hexdigest()
    offset=0
    if cursor is not None:
        try:
            if not isinstance(cursor,str) or not 1<=len(cursor)<=4096:
                raise ValueError()
            state=json.loads(base64.b64decode(cursor.encode('ascii'),altchars=b'-_',validate=True))
            if not isinstance(state,dict) or set(state)!={'version','export_fingerprint','offset'} or type(state['version']) is not int or state['version']!=1 or type(state['offset']) is not int or not 0<=state['offset']<len(rows):
                raise ValueError()
        except (ValueError,UnicodeError,TypeError,KeyError):
            raise ValueError('legacy_cursor_invalid') from None
        if state['export_fingerprint']!=fingerprint:
            raise ValueError('legacy_cursor_export_mismatch')
        offset=state['offset']
    counts={'known_raw_excerpts':0,'known_native_mirrors':0,'ambiguous_or_unrelated':0,'known_session_provenance':0}
    for row in rows:
        if not isinstance(row,dict) or not isinstance(row.get('metadata'),dict):
            counts['ambiguous_or_unrelated']+=1
            continue
        source=row['metadata'].get('source')
        source=source if isinstance(source,str) else None
        if source=='hermes.sync_turn':
            counts['known_raw_excerpts']+=1
        elif source in {'hermes.memory_write.add','hermes.memory_write.update'}:
            counts['known_native_mirrors']+=1
        else:
            counts['ambiguous_or_unrelated']+=1
            continue
        if row.get('session_id') or row['metadata'].get('session_id'):
            counts['known_session_provenance']+=1
    end=min(len(rows),offset+page_size)
    return {**counts,'protocol':'hermes_legacy_review.v1','dry_run':True,
            'export_fingerprint':fingerprint,'total_records':len(rows),'offset':offset,
            'records':[_legacy_record(row,index) for index,row in enumerate(rows[offset:end],offset)],
            'next_cursor':_review_cursor(fingerprint,end) if end<len(rows) else None,
            'originals_reconstructed':False,'native_ids_inferred':False,'automatic_historical_changes':False,
            'next_action':'review actual record IDs and provenance; reconcile complete native files separately; preserve ambiguous and independently supported records; explicit forget requires operator-selected IDs'}


def apply_sources(home, *, timeout=30):
    home=Path(home).expanduser().resolve()
    # This CLI process is explicitly selecting its profile; it never changes another process.
    os.environ['HERMES_HOME']=str(home)
    identity=None
    journal=home/'backplane-memory'/'delivery.sqlite3'
    if journal.exists():
        with sqlite3.connect(journal.as_uri()+'?mode=ro',uri=True) as db:
            row=db.execute("SELECT value FROM meta WHERE key='binding'").fetchone()
            identity=json.loads(row[0]).get('agent_identity') if row else None
    provider=load_plugin().BackplaneMemoryProvider()
    provider.initialize('',hermes_home=str(home),agent_identity=identity)
    try:
        sources=provider.reconcile_sources(dry_run=False)
        status=provider.flush(timeout=timeout,canonical=True)
        return {'dry_run':False,'sources':sources,'delivery':status,'success':all(row['complete'] for row in sources) and status['success']}
    finally:
        provider.shutdown()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hermes-home',required=True)
    parser.add_argument('--legacy-export')
    parser.add_argument('--legacy-page-size',type=int,default=50,help='Review 1..100 records from the immutable export')
    parser.add_argument('--legacy-cursor',help='Resume a prior review page from the exact same export bytes')
    parser.add_argument('--apply-sources',action='store_true',help='Explicitly reconcile only the selected native files; retains durable state for resume')
    parser.add_argument('--timeout',type=float,default=30)
    args=parser.parse_args()
    report=apply_sources(args.hermes_home,timeout=args.timeout) if args.apply_sources else inspect_profile(args.hermes_home)
    if args.legacy_export:
        report['legacy_review']=inspect_legacy_export(args.legacy_export,page_size=args.legacy_page_size,cursor=args.legacy_cursor)
    print(json.dumps(report))
    if report.get('success') is False:
        raise SystemExit(1)
