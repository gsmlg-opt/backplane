"""Real macOS pipe protocol checks; accepts a built session helper path."""
import os
import select
import signal
import struct
import subprocess
import sys
import time
import unittest
from pathlib import Path

HELPER = os.path.abspath(sys.argv.pop(1)) if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[2] / "priv/bin/backplane-local-command-session")


class Pipe:
    def __init__(self, command):
        self.proc = subprocess.Popen(
            [HELPER, "--pipe-ack", "nonce", "b3duZXI", "1", "17", "24", "80",
             "1500", "1048576", "/bin/sh", "-c", command],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.buffer = bytearray()
        ready = self.receive()
        assert ready[:1] == b"R", ready
        self.evidence = ready[1:]
        fields = self.evidence.split()
        self.guardian, self.child = int(fields[4]), int(fields[6])
        self.send(b"Anonce")

    def send(self, data):
        self.proc.stdin.write(struct.pack("!I", len(data)) + data)
        self.proc.stdin.flush()

    def receive(self, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if len(self.buffer) >= 4:
                size = struct.unpack("!I", self.buffer[:4])[0]
                if len(self.buffer) >= size + 4:
                    data = bytes(self.buffer[4:size+4])
                    del self.buffer[:size+4]
                    return data
            if select.select([self.proc.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                chunk = os.read(self.proc.stdout.fileno(), 65540)
                if not chunk:
                    raise AssertionError("unexpected helper EOF")
                self.buffer.extend(chunk)
        raise AssertionError("helper frame timeout")

    def finish(self):
        output, eof, proof = bytearray(), False, None
        while proof is None:
            data = self.receive()
            if data[:1] == b"O":
                output.extend(data[1:])
            elif data == b"E":
                eof = True
            elif data[:1] == b"F":
                proof = data[1:]
        assert proof.startswith(self.evidence + b"|"), proof
        assert b"|confirmed|closed|dispatched|reaped|none" in proof, proof
        self.send(b"Q")
        assert self.proc.wait(timeout=3) == 0
        return bytes(output), eof

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        self.proc.stdout.close()
        if not self.proc.stdin.closed:
            self.proc.stdin.close()


def absent(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        text = subprocess.check_output([HELPER, "--alive", str(pid)])
        if text == b"absent\n":
            return True
        time.sleep(0.01)
    return False


@unittest.skipUnless(sys.platform == "darwin", "native macOS helper")
class MacPipeProtocol(unittest.TestCase):
    def pipe(self, command):
        pipe = Pipe(command)
        self.addCleanup(pipe.close)
        return pipe

    def test_literal_input_eof_and_late_split_utf8_output(self):
        pipe = self.pipe("cat; printf '\\342'; sleep 0.05; printf '\\202\\254'; sleep 0.05; printf FINAL")
        pipe.send(b"Ipayload-without-newline")
        pipe.send(b"E")
        self.assertEqual(pipe.finish(), (b"payload-without-newline\xe2\x82\xacFINAL", True))

    def test_empty_eof(self):
        pipe = self.pipe("cat; printf EMPTY")
        pipe.send(b"E")
        self.assertEqual(pipe.finish(), (b"EMPTY", True))

    def test_large_output_tail_is_drained(self):
        pipe = self.pipe("cat; dd if=/dev/zero bs=1024 count=128 2>/dev/null; printf TAIL")
        pipe.send(b"E")
        self.assertEqual(pipe.finish(), (b"\0" * 131072 + b"TAIL", True))

    def test_slow_reader_applies_backpressure_without_losing_output(self):
        pipe = self.pipe("cat; dd if=/dev/zero bs=1024 count=768 2>/dev/null; printf TAIL")
        pipe.send(b"E")
        time.sleep(0.3)
        self.assertEqual(pipe.finish(), (b"\0" * 786432 + b"TAIL", True))

    def test_control_eof_cleans_real_process_group(self):
        pipe = self.pipe("sleep 60 & wait")
        pipe.proc.stdin.close()
        pipe.proc.wait(timeout=5)
        self.assertTrue(absent(pipe.child))
        self.assertTrue(absent(pipe.guardian))

    def test_broker_death_cleans_real_process_group(self):
        pipe = self.pipe("sleep 60 & wait")
        os.kill(pipe.proc.pid, signal.SIGKILL)
        pipe.proc.wait(timeout=3)
        self.assertTrue(absent(pipe.child))
        self.assertTrue(absent(pipe.guardian))

    def test_descendants_in_original_group_are_cleaned(self):
        pipe = self.pipe("sleep 60 & printf '%s' $!; cat")
        first = pipe.receive()
        self.assertEqual(first[:1], b"O")
        descendant = int(first[1:])
        pipe.send(b"E")
        output, eof = pipe.finish()
        self.assertEqual(output, b"")
        self.assertTrue(eof)
        self.assertTrue(absent(descendant))


if __name__ == "__main__":
    unittest.main()
