import json, os, signal, sys, time
if os.environ.get('MCP_LAUNCH_LOG'):
    with open(os.environ['MCP_LAUNCH_LOG'], 'a') as log: log.write(str(os.getpid())+'\n')
mode = sys.argv[1]
if mode == 'echo':
    for line in sys.stdin:
        request = json.loads(line)
        result = {'argv': sys.argv[2:], 'cwd': os.getcwd(), 'value': os.environ.get('MCP_FIXTURE_VALUE')}
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
elif mode == 'term':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print('ready', flush=True)
    while True: time.sleep(0.01)
elif mode == 'kill':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('ready', flush=True)
    while True: time.sleep(0.01)
elif mode == 'nonzero':
    print('ready', flush=True)
    sys.exit(23)
elif mode == 'descendant':
    if os.fork() == 0:
        time.sleep(2)
        os._exit(0)
    print('ready', flush=True)
    sys.exit(0)
elif mode == 'output':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for _ in range(128): os.write(1, b'x'*16384)
    while True: time.sleep(0.01)
