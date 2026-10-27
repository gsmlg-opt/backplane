#!/usr/bin/env python3
"""Synthetic negative-only guardian protocol fixture; never launches a target."""
import os, struct, sys
if sys.argv[1:] == ['--probe']:
    print('backplane-mcp-stdio-guardian 1')
    sys.exit(0)
token=bytes.fromhex(sys.argv[2])
def write(kind,payload=b''):
    sys.stdout.buffer.write(struct.pack('!I',len(payload)+1)+bytes([kind])+payload)
    sys.stdout.buffer.flush()
def read():
    header=sys.stdin.buffer.read(4)
    if not header: return None
    return sys.stdin.buffer.read(struct.unpack('!I',header)[0])
write(1,b'\0\1'+token)
assert read() == b'\2'+token
write(3,token+struct.pack('!I',1001))
while True:
    packet=read()
    if packet is None: break
    if packet[0] == 6:
        mode=os.environ['MCP_GUARD_FAULT']
        if mode == 'missing': break
        if mode == 'deadline': continue
        nonce=packet[17:33]
        if mode == 'wrong_nonce': nonce=bytes(16)
        write(7,token+nonce+struct.pack('!I',1001)+b'\0'+struct.pack('!I',0)+b'\1\1\0\0')
        sys.exit(7 if mode == 'nonzero_helper' else 0)
