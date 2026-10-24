"""Regenerate checked-in fixtures with the locked development-only Rust oracle."""
import glob
import hashlib
import json
from pathlib import Path
import subprocess
import string

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURES = ROOT / 'apps/backplane_agent_runtime/test/fixtures/tool_search'
FIXTURES.mkdir(parents=True, exist_ok=True)
ORACLE = HERE / 'target/debug/backplane-tool-search-oracle'

def generate(name, request):
    result = subprocess.run([str(ORACLE)], input=json.dumps(request, ensure_ascii=False)+'\n', text=True, capture_output=True, check=True)
    fixture = {'input': request, 'expected': json.loads(result.stdout)}
    (FIXTURES / (name+'.json')).write_text(json.dumps(fixture, ensure_ascii=False, indent=2)+'\n')

schema = {'type':'object', 'description':'Root credential inspection', 'properties': {
    'zebra': {'type':'array','description':'Batch details','items': {'type':'object','properties': {'secret': {'type':'string','description':'Password rotation'}}}},
    'alpha': {'anyOf': [{'type':'string','description':'Token lookup'}, {'type':'number','description':'Numeric identifier'}]}
}, 'enum':['excluded_enum'], '$defs':{'excluded_defs':{'description':'excluded_definition'}}}
contracts = [
 {'name':'read_credentials','description':' Inspect vault credentials. ','schema':schema},
 {'namespace':'vault','name':'lookup_account','description':'Retrieve credentials','metadata':{'namespace_description':'Secure account directory'},'schema':{'type':'object'}},
 {'namespace':'vault','name':'store_secret','description':'Persist tokens','schema':{'type':'object'}},
 {'namespace':'functions','name':'list_items','description':'List','schema':{'type':'object'}},
 {'namespace':'grammar','name':'parse_input','description':'Parse expressions','input_kind':'custom','format':{'syntax':'lark','definition':'excluded_grammar'}},
 {'name':'custom_input','description':'Text input','input_kind':'custom','format':{'type':'text'}},
 {'namespace':'blank','name':'lookup','description':'Account','metadata':{'namespace_description':'  '},'schema':{'type':'object'}},
]
generate('metadata', {'contracts':contracts, 'queries':['credential','secure account','password rotation','lark','excluded_enum excluded_defs excluded_definition excluded_grammar','read credentials','functions']})
texts = ["Éléphant Straße Æneid 北亰 中文 🍕🚀🍋 🦄☣", "\u0378 \U0010ffff é\u0301",
 "can't you're won't let's couldn't've John's O'Reilly l'amour foo_bar __ __foo bar__ a1 1a 3.14 1,234 1;23 a:b a.b a,b a;z 3:4 a.1 1.a 1_2",
 "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", 'the and is', '', 'alpha alpha rare', 'alpha beta gamma delta epsilon', 'rare', 'alpha', 'alpha',
 "\x00\x7f\n\té\u200d𐍈"]
generate('tokens-ranking', {'texts':texts,'queries':['alpha','alpha alpha rare','rare','the and is','北亰 pizza','unknown','3.14 foo_bar']})
boundary_texts = [f"{a}{p}{b}" for a in ['a','1','_'] for b in ['b','2','_'] for p in ["'",':','.',',',';','_','--',"''"]]
generate('ascii-boundaries', {'texts':boundary_texts,'queries':[]})
edge_words = ['alpha', '123', 'the', "don't", 'alpha.beta', '3.14', 'foo_bar', '_']
edge_texts = [text for word in edge_words for punctuation in string.punctuation
              for text in [punctuation + word, word + punctuation, punctuation + word + punctuation]]
edge_texts += [left + word + right for word in ['alpha', '123', 'the']
               for left in ["'", '.', ':', ',', ';', "''", '..']
               for right in ['', "'", '.', ':', ',', ';']]
generate('ascii-edge-boundaries', {'texts':edge_texts, 'queries':['alpha', '123', "'the", '.alpha', ';123']})
vocab = Path(glob.glob(str(Path.home()/'.cargo/registry/src/*/rust-stemmers-1.2.0/test_data/voc_en.txt'))[0]).read_text().splitlines()
exceptions = 'skis skies dying lying tying idly gently ugly early only singly sky news howe atlas cosmos bias andes inning outing canning herring earring proceed exceed succeed'.split()
# Every official Snowball vocabulary word is checked, grouped to keep fixtures compact.
words = exceptions + vocab
texts = [' '.join(words[i:i+100]) for i in range(0,len(words),100)]
generate('snowball-vocabulary', {'texts':texts,'queries':[]})
for name,texts,queries in [('empty',[],['rare']),('zero-tokens',['the and is','','a'],['rare','the']),('idf-length',['rare common common','common','common other','rare '+('padding '*100)],['rare','common','rare rare common'])]:
 generate(name,{'texts':texts,'queries':queries})
# Deterministic collision of Rust FxHash32 ASCII tokens, verified by the Rust oracle.
seen = {}
def fx(token):
 h=0
 def word(h,v): return ((((h<<5)|(h>>27)) & 0xffffffff)^v)*0x27220a95 & 0xffffffff
 b=token.encode()
 while len(b)>=4: h=word(h,int.from_bytes(b[:4],'little'));b=b[4:]
 for c in b: h=word(h,c)
 return word(h,255)
for i in range(400000):
 token = 'q'+hashlib.sha256(str(i).encode()).hexdigest()[:13].replace('e','q')+'z'
 h=fx(token)
 if h in seen:
  a,b=seen[h],token
  generate('hash-collision',{'texts':[a,b,'unrelated'], 'queries':[a,b,a+' '+a]})
  break
 seen[h]=token
else: raise RuntimeError('collision fixture not found')
