"""Local preparation checks for the frozen Backplane.MemorySourceContract v1.

The host remains authoritative. These checks prevent durably queueing commands
that the supported peer must reject; nothing is truncated to satisfy a limit.
"""
from datetime import datetime
import hashlib
import re
import uuid

from .delivery import canonical_json

LIMITS = {'page_entries':100,'pages':100,'entries':10000,'snapshot_bytes':16777216,
          'content_bytes':262144,'page_bytes':480000}
PROVENANCE = {'session_id','parent_session_id','message_uid','tool_call_uid','tool_call_id',
              'role','author','repository_sources','cwd','write_origin','execution_context'}
RESERVED = {'host_id','client_id','source_client_id','memory_space_id','scope','namespace',
            'partition','requesting_actor','authority_version','access_id'}
UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')


class SourceValidationError(ValueError):
    pass


def require(condition,code='invalid_source_payload'):
    if not condition:
        raise SourceValidationError(code)


def portable(value,depth=0):
    require(depth<=100)
    if isinstance(value,str):
        value.encode('utf-8')
    elif value is None or type(value) in (int,bool):
        pass
    elif isinstance(value,list):
        for item in value:
            portable(item,depth+1)
    elif isinstance(value,dict):
        require(all(isinstance(key,str) and key not in RESERVED for key in value))
        for key,item in value.items():
            key.encode('utf-8')
            portable(item,depth+1)
    else:
        require(False)


def text(value,limit):
    return isinstance(value,str) and bool(value.strip()) and '\x00' not in value and 1<=len(value.encode('utf-8'))<=limit


def identifier(value):
    return isinstance(value,str) and UUID.fullmatch(value) is not None


def provenance(value):
    require(isinstance(value,dict) and not set(value)-PROVENANCE)
    portable(value)
    for key,item in value.items():
        if key=='author':
            require(isinstance(item,dict))
        elif key=='repository_sources':
            require(isinstance(item,list) and len(item)<=32 and all(isinstance(source,dict) for source in item))
        elif key=='role':
            require(isinstance(item,str) and item in {'user','assistant','tool','operator','system'})
        else:
            require(text(item,4096))


def entry(value):
    require(isinstance(value,dict) and set(value)=={'entry_id','content','type','provenance'})
    require(identifier(value['entry_id']) and value['type']=='semantic' and text(value['content'],LIMITS['content_bytes']))
    provenance(value['provenance'])


def payload(value):
    portable(value)
    require(value.get('protocol')=='memory_sources.v1' and identifier(value.get('event_id')))
    src=value.get('source')
    require(isinstance(src,dict) and set(src)=={'integration','installation_id','profile_id','target'})
    require(src['integration']=='hermes' and identifier(src['installation_id']) and text(src['profile_id'],512) and src['target'] in {'memory','user'})
    require('memory_access_id' not in value or identifier(value['memory_access_id']))
    fields=set(value)-{'memory_access_id'}
    common={'protocol','source','event_id'}
    if 'operation' in value:
        required=common|{'entry_id','revision','operation','type','occurred_at','provenance'}
        require(fields in (required,required|{'content'}))
        require(identifier(value.get('entry_id')) and value.get('type')=='semantic')
        require(type(value.get('revision')) is int and 0<value['revision']<=9223372036854775807)
        provenance(value.get('provenance'))
        try:
            stamp=datetime.fromisoformat(value['occurred_at'].replace('Z','+00:00'))
            require(stamp.utcoffset() is not None)
        except (ValueError,TypeError,AttributeError):
            require(False)
        if value['operation']=='upsert':
            require(text(value.get('content'),LIMITS['content_bytes']))
        else:
            require(value['operation']=='withdraw' and 'content' not in value)
    else:
        require(identifier(value.get('reconciliation_id')))
        common|={'reconciliation_id','phase'}
        phase=value.get('phase')
        if phase=='begin':
            require(fields==common|{'revision','page_count','entry_count','snapshot_hash'})
            require(type(value.get('revision')) is int and 0<value['revision']<=9223372036854775807)
            require(type(value.get('page_count')) is int and 0<=value['page_count']<=LIMITS['pages'])
            require(type(value.get('entry_count')) is int and 0<=value['entry_count']<=LIMITS['entries'])
            require(value['page_count']>0 or value['entry_count']==0)
            require(isinstance(value.get('snapshot_hash'),str) and re.fullmatch('[0-9a-f]{64}',value['snapshot_hash']) is not None)
        elif phase=='page':
            require(fields==common|{'page_index','page_hash','entries'})
            require(type(value.get('page_index')) is int and 0<=value['page_index']<LIMITS['pages'])
            require(isinstance(value.get('entries'),list) and len(value['entries'])<=LIMITS['page_entries'])
            for item in value['entries']:
                entry(item)
            require(hashlib.sha256(canonical_json(value['entries']).encode()).hexdigest()==value.get('page_hash'))
        else:
            require(phase=='commit' and fields==common|{'complete'} and value.get('complete') is True)
    require(len(canonical_json(value).encode())<=LIMITS['page_bytes'],'source_command_too_large')
    return value


def snapshot(provider,target,entries):
    """Build and validate the entire manifest before the first enqueue."""
    require(len(entries)<=LIMITS['entries'],'source_snapshot_too_large')
    encoded=[]
    total=2
    identities=set()
    for item in entries:
        entry(item)
        require(item['entry_id'] not in identities)
        identities.add(item['entry_id'])
        raw=canonical_json(item).encode()
        total+=len(raw)+(1 if encoded else 0)
        require(total<=LIMITS['snapshot_bytes'],'source_snapshot_too_large')
        encoded.append(raw)
    digest=hashlib.sha256(b'['+b','.join(encoded)+b']').hexdigest()
    common={**provider._source_common(target),'reconciliation_id':str(uuid.uuid4())}
    def command(body):
        return {**common,'event_id':str(uuid.uuid4()),**body}
    pages=[]
    page=command({'phase':'page','page_index':0,'page_hash':'0'*64,'entries':[]})
    empty_size=len(canonical_json(page).encode())
    size=empty_size
    for item,raw in zip(entries,encoded):
        extra=len(raw)+(1 if page['entries'] else 0)
        if page['entries'] and (len(page['entries'])>=LIMITS['page_entries'] or size+extra>LIMITS['page_bytes']):
            pages.append(page)
            require(len(pages)<LIMITS['pages'],'source_snapshot_too_large')
            page=command({'phase':'page','page_index':len(pages),'page_hash':'0'*64,'entries':[]})
            empty_size=len(canonical_json(page).encode())
            size=empty_size
            extra=len(raw)
        require(size+extra<=LIMITS['page_bytes'],'source_command_too_large')
        page['entries'].append(item)
        size+=extra
    if page['entries']:
        pages.append(page)
    commands=[command({'phase':'begin','revision':provider._journal.sequence('source:'+target),
                       'page_count':len(pages),'entry_count':len(entries),'snapshot_hash':digest})]
    for page in pages:
        page['page_hash']=hashlib.sha256(canonical_json(page['entries']).encode()).hexdigest()
        commands.append(page)
    commands.append(command({'phase':'commit','complete':True}))
    return [payload(value) for value in commands]
