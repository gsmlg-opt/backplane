#!/usr/bin/env python3
"""Real POSIX child/packet tests. Invoke with a previously explicitly built helper."""
import json, os, select, signal, struct, subprocess, sys, time, unittest, shutil, tempfile
HELPER = os.path.abspath(sys.argv.pop(1))
TOKEN = bytes(range(16))
CLOSE = bytes(range(16,32))

def frame(kind, payload=b''):
    return struct.pack('!I', len(payload)+1) + bytes([kind]) + payload

class Guardian:
    def __init__(self, args):
        self.proc = subprocess.Popen([HELPER, '--token', TOKEN.hex(), '--'] + args,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.buffer = b''
        self.pid = None
        self.events = []
    def send(self, kind, payload=b''):
        self.proc.stdin.write(frame(kind, payload)); self.proc.stdin.flush()
    def receive(self, deadline):
        while True:
            if len(self.buffer) >= 4:
                size = struct.unpack('!I', self.buffer[:4])[0]
                assert 0 < size <= 65537
                if len(self.buffer) >= size+4:
                    packet, self.buffer = self.buffer[4:4+size], self.buffer[4+size:]
                    self.events.append(packet)
                    return packet
            remaining = deadline-time.monotonic()
            if remaining <= 0: raise TimeoutError('guardian packet deadline')
            if not select.select([self.proc.stdout], [], [], remaining)[0]: raise TimeoutError('guardian output deadline')
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk: raise EOFError('guardian EOF')
            self.buffer += chunk
    def start(self):
        hello = self.receive(time.monotonic()+2)
        assert hello == bytes([1,0,1])+TOKEN
        self.send(2, TOKEN)
        while True:
            packet = self.receive(time.monotonic()+2)
            if packet[0] == 3:
                assert packet[1:17] == TOKEN
                self.pid = struct.unpack('!I', packet[17:21])[0]
                return self.pid
    def close(self, budget=1000):
        self.send(6, TOKEN+CLOSE+struct.pack('!I',budget))
        while True:
            packet=self.receive(time.monotonic()+budget/1000+1)
            if packet[0] == 7:
                assert packet[1:17] == TOKEN and packet[17:33] == CLOSE
                assert packet[42:44] == b'\1\1'
                assert self.proc.wait(timeout=1) == 0
                return packet
    def cleanup(self):
        if self.proc.poll() is None:
            try: self.proc.stdin.close()
            except OSError: pass
            try: self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired: self.proc.kill(); self.proc.wait()
        for stream in [self.proc.stdin, self.proc.stdout]:
            if not stream.closed: stream.close()

class NativeTests(unittest.TestCase):
    def guardian(self, *args):
        guard=Guardian(list(args)); self.addCleanup(guard.cleanup); return guard
    def test_probe(self):
        self.assertEqual(subprocess.check_output([HELPER,'--probe']), b'backplane-mcp-stdio-guardian 1\n')
    def test_no_launch_before_ack(self):
        guard=self.guardian('/bin/sh','-c','echo launched')
        self.assertEqual(guard.receive(time.monotonic()+1)[0],1)
        self.assertFalse(select.select([guard.proc.stdout],[],[],0.05)[0])
        guard.send(2, bytes(16))
        self.assertEqual(guard.receive(time.monotonic()+1)[0],8)
        self.assertNotEqual(guard.proc.wait(timeout=2),0)
    def test_bytes_and_eof(self):
        guard=self.guardian(shutil.which('cat')); guard.start()
        payload=b'{"jsonrpc":"2.0","id":1,"result":{}}\n'
        guard.send(4,payload)
        self.assertEqual(guard.receive(time.monotonic()+1), b'\5'+payload)
        receipt=guard.close()
        self.assertEqual(receipt[37:42], b'\0\0\0\0\0')
        self.assertEqual(receipt[44:46], b'\0\0')
    def test_target_cannot_impersonate_control(self):
        guard=self.guardian(shutil.which('cat')); guard.start()
        payload=frame(7,TOKEN+CLOSE+bytes(13))
        guard.send(4,payload)
        self.assertEqual(guard.receive(time.monotonic()+1),b'\5'+payload)
        guard.close()
    def assert_buffered_exit_output(self, closing):
        payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': 'x'*60000}).encode()+b'\n'
        with tempfile.TemporaryDirectory(prefix='mcp-stdio-drain-') as directory:
            trigger = os.path.join(directory, 'trigger')
            done = os.path.join(directory, 'done')
            code = """import fcntl,json,os,sys,time
if hasattr(fcntl, 'F_SETPIPE_SZ'): fcntl.fcntl(1, fcntl.F_SETPIPE_SZ, 65536)
while not os.path.exists(sys.argv[1]): time.sleep(0.001)
payload=json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': 'x'*60000}).encode()+b'\\n'
while payload: payload=payload[os.write(1,payload):]
open(sys.argv[2], 'w').close()
"""
            guard=self.guardian(sys.executable,'-c',code,trigger,done)
            guard.start()
            os.kill(guard.proc.pid,signal.SIGSTOP)
            os.waitpid(guard.proc.pid,os.WUNTRACED)
            try:
                open(trigger,'w').close()
                deadline=time.monotonic()+2
                while not os.path.exists(done):
                    if time.monotonic() >= deadline: self.fail('target did not buffer its response')
                    time.sleep(0.001)
                # waitpid is the guardian's responsibility; let the target finish exiting.
                time.sleep(0.02)
                if closing: guard.send(6,TOKEN+CLOSE+struct.pack('!I',1000))
            finally:
                os.kill(guard.proc.pid,signal.SIGCONT)
            if closing:
                while guard.receive(time.monotonic()+2)[0] != 7: pass
                self.assertEqual(guard.proc.wait(timeout=1),0)
            else:
                while guard.receive(time.monotonic()+2)[0] != 9: pass
                guard.close()
            actual=b''.join(packet[1:] for packet in guard.events if packet[0] == 5)
            self.assertEqual(actual,payload)
            self.assertEqual(json.loads(actual)['result'],'x'*60000)
    def test_buffered_multichunk_response_survives_target_exit(self):
        self.assert_buffered_exit_output(False)
    def test_close_drains_buffered_multichunk_response(self):
        self.assert_buffered_exit_output(True)
    def test_term(self):
        guard=self.guardian('/bin/sh','-c','trap "exit 0" TERM; while :; do sleep 0.02; done')
        guard.start(); time.sleep(0.05)
        receipt=guard.close()
        self.assertEqual(receipt[44],1)
        self.assertEqual(receipt[45],0)
    def test_kill(self):
        guard=self.guardian('/bin/sh','-c','trap "" TERM; while :; do sleep 0.02; done')
        guard.start(); time.sleep(0.05)
        receipt=guard.close(500)
        self.assertEqual(receipt[37],1)
        self.assertEqual(struct.unpack('!I',receipt[38:42])[0],signal.SIGKILL)
        self.assertEqual(receipt[44:46],b'\1\1')
    def test_nonzero_exit(self):
        guard=self.guardian('/bin/sh','-c','exit 19'); guard.start()
        receipt=guard.close()
        self.assertEqual(struct.unpack('!I',receipt[38:42])[0],19)
    def test_descendant_retains_stdout(self):
        guard=self.guardian('/bin/sh','-c','sleep 2 & exit 0'); guard.start()
        started=time.monotonic(); receipt=guard.close(500)
        self.assertLess(time.monotonic()-started,0.5)
        self.assertEqual(receipt[42:44],b'\1\1')
    def test_saturated_output_close_progress(self):
        guard=self.guardian('/bin/sh','-c','trap "" TERM; yes output')
        guard.start(); time.sleep(0.15)
        guard.send(6,TOKEN+CLOSE+struct.pack('!I',1000))
        time.sleep(0.6)
        while True:
            packet=guard.receive(time.monotonic()+1)
            if packet[0]==7: break
        self.assertEqual(guard.proc.wait(timeout=1),0)
    def test_output_deadline_cannot_claim_a_delivered_receipt(self):
        guard=self.guardian('/bin/sh','-c','trap "" TERM; yes output')
        guard.start(); time.sleep(0.15)
        guard.send(6,TOKEN+CLOSE+struct.pack('!I',20))
        self.assertEqual(guard.proc.wait(timeout=1),75)
        received=[]
        try:
            while True: received.append(guard.receive(time.monotonic()+1)[0])
        except EOFError: pass
        self.assertNotIn(7,received)
    def test_reject_oversize_frame_without_launch(self):
        guard=self.guardian(shutil.which('cat'))
        guard.receive(time.monotonic()+1)
        guard.proc.stdin.write(struct.pack('!I',65538)); guard.proc.stdin.flush()
        self.assertEqual(guard.receive(time.monotonic()+1)[0],8)
        self.assertNotEqual(guard.proc.wait(timeout=2),0)

if __name__=='__main__': unittest.main()
