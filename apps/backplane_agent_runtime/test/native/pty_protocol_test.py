#!/usr/bin/env python3
"""Real Linux protocol acceptance; Python is only the test driver, never the transport."""
import os
import select
import signal
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HELPER = os.environ.get('PTY_HELPER', str(Path(__file__).parents[2] / 'priv/bin/backplane-local-command-pty'))


def send(proc, data):
    proc.stdin.write(struct.pack('!I', len(data)) + data)
    proc.stdin.flush()


def frame(proc, timeout=3):
    deadline = time.monotonic() + timeout
    data = b''
    for size in (4, None):
        if size is None:
            size = struct.unpack('!I', data)[0]
            assert 0 < size <= 65536
            data = b''
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([proc.stdout], [], [], remaining)[0]:
                raise AssertionError('native frame timed out')
            chunk = os.read(proc.stdout.fileno(), size - len(data))
            if not chunk:
                raise AssertionError('native helper closed without proof')
            data += chunk
    return data


def stopped(pid):
    try:
        return Path('/proc/%s/stat' % pid).read_text().rsplit(') ', 1)[1][0] in 'ZX'
    except FileNotFoundError:
        return True


class Protocol(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(HELPER), "first-party native helper has not been built")

    def launch(self, cmd, rows=24, cols=80, ack=True, output_limit=1048576):
        proc = subprocess.Popen([HELPER, '--run', 'test-launch', 'test-owner', '4', '11', str(rows), str(cols), '650', str(output_limit), '/bin/sh', '-c', cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.finish, proc)
        ready = frame(proc)
        self.assertTrue(ready.startswith(b'R1 test-launch '), ready)
        fields = ready[1:].decode().split()
        self.assertEqual(fields[-3:], ['test-owner', '4', '11'])
        proc.identity = ready[1:]
        proc.native_pids = [int(fields[i]) for i in (2, 4, 6)]
        if ack:
            send(proc, b'Atest-launch')
        return proc

    def finish(self, proc):
        if proc.poll() is None:
            try:
                send(proc, b'C')
                proc.communicate(timeout=2)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                proc.kill()
                proc.communicate(timeout=2)
        if not proc.stdin.closed: proc.stdin.close()
        proc.stdout.close()

    def collect(self, proc):
        output, events = b'', []
        while True:
            event = frame(proc)
            events.append(event)
            if event[:1] == b'O':
                output += event[1:]
            if event[:1] == b'F':
                self.assertEqual(event[1:].split(b'|')[0], proc.identity)
                proc.wait(timeout=2)
                return output, events

    def test_probe(self):
        result = subprocess.run([HELPER, '--probe'], stdout=subprocess.PIPE, timeout=3)
        self.assertEqual((result.returncode, result.stdout), (0, b'BACKPLANE_PTY 1\n'))

    def test_ready_ack_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = directory + '/effect'
            proc = self.launch('echo effect > ' + marker, ack=False)
            time.sleep(.08)
            self.assertFalse(os.path.exists(marker))
            send(proc, b'Atest-launch')
            _, events = self.collect(proc)
            self.assertTrue(os.path.exists(marker))
            self.assertIn(b'|0|confirmed|closed|dispatched|reaped|none', events[-1])

    def test_cancel_before_ack_is_never_dispatched(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = directory + '/effect'
            proc = self.launch('echo effect > ' + marker, ack=False)
            send(proc, b'C')
            _, events = self.collect(proc)
            self.assertFalse(os.path.exists(marker))
            self.assertIn(b'|confirmed|closed|never_started|reaped|none', events[-1])

    def test_eof_before_ack_has_no_target_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = directory + '/effect'
            proc = self.launch('echo effect > ' + marker, ack=False)
            proc.stdin.close()
            _, events = self.collect(proc)
            self.assertFalse(os.path.exists(marker))
            self.assertIn(b'|confirmed|closed|never_started|reaped|none', events[-1])

    def test_wrong_ack_cannot_execute_target(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = directory + '/effect'
            proc = self.launch('echo effect > ' + marker, ack=False)
            send(proc, b'Awrong-launch')
            _, events = self.collect(proc)
            self.assertFalse(os.path.exists(marker))
            self.assertIn(b'|never_started|', events[-1])

    def test_stopped_target_resumes_to_handle_term(self):
        proc = self.launch("trap 'printf HANDLED; exit 0' TERM; kill -STOP $$; while :; do :; done")
        time.sleep(.03)
        send(proc, b'C')
        output, events = self.collect(proc)
        self.assertIn(b'HANDLED', output)
        self.assertIn(b'|confirmed|closed|', events[-1])

    def test_term_ignoring_multiple_groups_are_killed(self):
        proc = self.launch('exec /bin/bash --noprofile --norc -i')
        send(proc, b"Itrap '' TERM; sleep 30 & sleep 30 & echo BOTH:$!; wait\n")
        output = b''
        while not __import__('re').search(rb'BOTH:(\d+)', output):
            event = frame(proc)
            if event[:1] == b'O': output += event[1:]
        send(proc, b'C')
        _, events = self.collect(proc)
        self.assertIn(b'|confirmed|closed|', events[-1])

    def test_forking_during_cleanup_is_discovered_before_confirmation(self):
        proc = self.launch("trap '' TERM; printf 'SPAWNER:%s\\n' $$; i=0; while [ \"$i\" -lt 30 ]; do sleep .01 & printf 'FORK:%s\\n' $!; i=$((i+1)); done; wait")
        output = b''
        while not __import__('re').search(rb'SPAWNER:(\d+)', output):
            event = frame(proc)
            if event[:1] == b'O': output += event[1:]
        send(proc, b'C')
        rest, events = self.collect(proc)
        children = __import__('re').findall(rb'FORK:(\d+)', output + rest)
        self.assertTrue(children)
        self.assertTrue(all(stopped(int(child)) for child in children))
        self.assertIn(b'|confirmed|closed|', events[-1])

    def test_controlling_terminal_dimensions_bytes_input(self):
        proc = self.launch('test -t 0 && test -t 1 && test -t 2 || exit 9; stty size; printf "PROMPT>"; read answer; printf "\\033[31m%s\\033[0m\\n" "$answer"', 33, 99)
        output = b''
        while b'PROMPT>' not in output:
            event = frame(proc)
            self.assertEqual(event[:1], b'O')
            output += event[1:]
        self.assertIn(b'33 99\r\n', output)
        send(proc, b'Iinput\n')
        rest, events = self.collect(proc)
        self.assertIn(b'\x1b[31minput\x1b[0m\r\n', rest)
        self.assertIn(b'|0|confirmed|', events[-1])

    def test_leader_exit_cleans_additional_job_control_groups(self):
        # Interactive shell creates a distinct background process group.
        proc = self.launch("exec /bin/bash --noprofile --norc -i")
        send(proc, b'Isleep 30 &\necho CHILD:$!\nexit\n')
        output, events = self.collect(proc)
        import re
        child = int(re.search(rb'CHILD:(\d+)', output).group(1))
        self.assertTrue(stopped(child))
        self.assertIn(b'|confirmed|closed|', events[-1])

    def test_ctrl_c_only_interrupts_foreground_then_cancel_session(self):
        proc = self.launch('exec /bin/bash --noprofile --norc -i')
        send(proc, b'Isleep 30 &\necho CHILD:$!\nsleep 30\n')
        output = b''
        while b'CHILD:' not in output or not __import__('re').search(rb'CHILD:(\d+)', output):
            event = frame(proc)
            if event[:1] == b'O': output += event[1:]
        time.sleep(.08)
        send(proc, b'I\x03')
        send(proc, b'Iecho AFTER_INTERRUPT\n')
        while b'AFTER_INTERRUPT\r\n' not in output:
            event = frame(proc)
            if event[:1] == b'O': output += event[1:]
        self.assertIsNone(proc.poll())
        send(proc, b'C')
        _, events = self.collect(proc)
        self.assertIn(b'|confirmed|closed|', events[-1])

    def test_broker_death_triggers_guardian_cleanup(self):
        proc = self.launch('exec sleep 30')
        broker, guardian, child = proc.native_pids
        os.kill(broker, signal.SIGKILL)
        proc.wait(timeout=2)
        until = time.monotonic() + 2
        while time.monotonic() < until and not (stopped(guardian) and stopped(child)):
            time.sleep(.01)
        self.assertTrue(stopped(child))
        self.assertTrue(stopped(guardian))
        # No final proof can exist after broker death.
        self.assertEqual(proc.stdout.read(), b'')

    def test_guardian_death_is_explicitly_uncertain(self):
        proc = self.launch('exec sleep 30')
        os.kill(proc.native_pids[1], signal.SIGKILL)
        _, events = self.collect(proc)
        self.assertIn(b'|uncertain|unknown|', events[-1])

    def test_backpressure_does_not_block_lifeline_cleanup(self):
        proc = self.launch('while :; do printf "0123456789012345678901234567890123456789"; done')
        time.sleep(.15)
        proc.stdin.close()
        # Deliberately stop consuming Port output; guardian must still exit.
        until = time.monotonic() + 2
        while time.monotonic() < until and not stopped(proc.native_pids[1]):
            time.sleep(.01)
        self.assertTrue(stopped(proc.native_pids[1]))
        self.assertTrue(stopped(proc.native_pids[2]))
        proc.wait(timeout=2)

    def test_output_hard_cap_reports_limit(self):
        proc = self.launch('while :; do printf xxxxxxxxxxxxxxxxxx; done', output_limit=128)
        output, events = self.collect(proc)
        self.assertLessEqual(len(output), 128)
        self.assertTrue(any(event == b'L' for event in events))
        self.assertIn(b'|confirmed|closed|', events[-1])


if __name__ == '__main__':
    unittest.main(verbosity=2)
