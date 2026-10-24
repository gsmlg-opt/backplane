"""Real HTTP deadline and tracked-worker shutdown regressions."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_hermes_runtime import capability, current, plugin


@contextmanager
def slow_http(dispatch):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers['Content-Length']))
            body = dispatch(self.path, json.loads(raw), raw)
            encoded = json.dumps(body).encode()
            try:
                self.send_response(200)
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The fault case deliberately times out after acceptance.

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        yield 'http://127.0.0.1:' + str(server.server_port)
    finally:
        server.shutdown()
        server.server_close()  # Joins every owned request handler too.
        worker.join(timeout=2)
        assert not worker.is_alive()


class DeadlineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.providers = []
        self.addCleanup(self.close_providers)

    def close_providers(self):
        for provider in self.providers:
            provider.shutdown()
            if provider._worker:
                provider._worker.join(timeout=25)
                self.assertFalse(provider._worker.is_alive())
            try:
                self.assertIsNone(provider._journal.db)
            finally:
                provider._journal.close()

    def build(self, base, *, worker=False):
        (self.home / 'backplane-memory.json').write_text(json.dumps({'url': base}))
        provider = plugin.BackplaneMemoryProvider()
        with patch.dict(plugin.os.environ, {}, clear=True), patch.object(plugin, '_load_egress_scrubber', return_value=lambda text: text):
            if worker:
                provider.initialize('deadline-session', hermes_home=self.home, agent_context='subagent')
            else:
                with patch.object(provider, '_start_worker'):
                    provider.initialize('deadline-session', hermes_home=self.home, agent_context='subagent')
        self.providers.append(provider)
        return provider

    @staticmethod
    def enqueue(provider):
        payload = {'protocol': 'hermes_capture.v1', 'event_id': 'immutable-event',
                   'session_id': 'deadline-session', 'content': 'retained evidence'}
        provider._journal.enqueue(payload['event_id'], '/capture/v1/hooks/hermes/message', payload)
        return payload

    def test_default_http_deadline_allows_slow_async_recall(self):
        def dispatch(path, _payload, _raw):
            if path.endswith('source_capabilities'):
                return {'ok': True, 'result': capability()}
            self.assertTrue(path.endswith('/recall'))
            time.sleep(2.3)  # Real canonical recalls exceeded the former 2s limit.
            return {'ok': True, 'result': {'results': [current('alpha slow recall')]}}

        with slow_http(dispatch) as base:
            provider = self.build(base, worker=True)
            started = time.monotonic()
            self.assertEqual(provider.prefetch('alpha'), '')
            self.assertLess(time.monotonic() - started, 0.2)
            key = ('deadline-session', 'alpha', provider._generation)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                with provider._state_lock:
                    cached = provider._cache.get(key)
                if cached:
                    break
                time.sleep(0.02)
            self.assertIsNotNone(cached, 'normal slow recall was discarded by the HTTP deadline')
            self.assertIn('alpha slow recall', provider.prefetch('alpha'))
            provider.shutdown()

    def test_timeout_after_acceptance_replays_immutable_payload_after_restart(self):
        accepted, attempts, bodies = {}, [], []
        release = threading.Event()

        def dispatch(path, payload, raw):
            if path.endswith('source_capabilities'):
                return {'ok': True, 'result': capability()}
            if path == '/capture/v1/status':
                return {'ok': True, 'result': {'protocol': 'hermes_capture.v1',
                        'items': [{'event_id': 'immutable-event', 'status': 'canonical_committed'}]}}
            event = payload['event_id']
            accepted.setdefault(event, raw)
            attempts.append(event)
            bodies.append(raw)
            if len(attempts) == 1:
                release.wait(timeout=2)
            return {'ok': True, 'status': 'duplicate', 'event_id': event}

        with slow_http(dispatch) as base:
            first = self.build(base)
            payload = self.enqueue(first)
            try:
                # Fault injection only; the slow-recall test uses the production limit.
                with patch.object(plugin, 'TIMEOUT', 0.15):
                    first._deliver_once()
                self.assertEqual(first.delivery_status()['local_pending'], 1)
                self.assertEqual(first.delivery_status()['canonical_committed'], 0)
                first.shutdown()
            finally:
                release.set()
            second = self.build(base)
            second._journal.db.execute('UPDATE delivery SET next_at=0')
            second._deliver_once()
            self.assertEqual(second.delivery_status()['host_accepted'], 1)
            second._journal.db.execute('UPDATE delivery SET next_at=0')
            second._deliver_once()
            self.assertEqual(second.delivery_status()['canonical_committed'], 1)
            self.assertEqual(second.delivery_status()['local_pending'], 0)
            self.assertEqual(attempts, ['immutable-event', 'immutable-event'])
            self.assertEqual(len(accepted), 1)
            self.assertEqual(bodies[0], bodies[1])
            self.assertEqual(json.loads(bodies[1]), payload)

    def test_shutdown_retains_inflight_journal_then_restart_observes_host_receipt(self):
        accepted, release = threading.Event(), threading.Event()

        def dispatch(path, payload, _raw):
            if path.endswith('source_capabilities'):
                return {'ok': True, 'result': capability()}
            if path == '/capture/v1/status':
                return {'ok': True, 'result': {'protocol': 'hermes_capture.v1',
                        'items': [{'event_id': 'immutable-event', 'status': 'canonical_committed'}]}}
            accepted.set()
            release.wait(timeout=10)
            return {'ok': True, 'status': 'accepted', 'event_id': payload['event_id']}

        with slow_http(dispatch) as base:
            first = self.build(base)
            payload = self.enqueue(first)
            first._start_worker()
            try:
                self.assertTrue(accepted.wait(timeout=2))
                started = time.monotonic()
                first.shutdown()
                self.assertLess(time.monotonic() - started, 6)
                self.assertTrue(first.delivery_status()['worker_alive'])
                self.assertEqual(first.delivery_status()['canonical_committed'], 0)
                self.assertIsNotNone(first._journal.db, 'in-flight worker still owns the journal')
            finally:
                release.set()
                first._worker.join(timeout=3)
            self.assertFalse(first._worker.is_alive())
            self.assertIsNone(first._journal.db)
            second = self.build(base)
            row = second._journal.db.execute('SELECT payload,state FROM delivery').fetchone()
            self.assertEqual(json.loads(row['payload']), payload)
            self.assertEqual(row['state'], 'host_accepted')
            second._journal.db.execute('UPDATE delivery SET next_at=0')
            second._deliver_once()
            self.assertEqual(second.delivery_status()['canonical_committed'], 1)

    def test_shutdown_closes_journal_when_worker_finalizer_finished_before_thread_exit(self):
        provider = self.build('http://127.0.0.1:1')
        finalized, release = threading.Event(), threading.Event()
        original = provider._worker_loop

        def retiring_worker():
            original()
            finalized.set()
            release.wait(timeout=10)

        provider._stopping.set()
        provider._worker_loop = retiring_worker
        provider._start_worker()
        try:
            self.assertTrue(finalized.wait(timeout=2))
            provider.shutdown()
            self.assertTrue(provider._worker.is_alive())
            self.assertIsNone(provider._journal.db, 'worker finalization already released journal ownership')
        finally:
            release.set()
            provider._worker.join(timeout=2)
            provider._journal.close()

    def test_stopping_during_delivery_does_not_start_queued_recall(self):
        provider = self.build('http://127.0.0.1:1')
        provider.queue_prefetch('alpha')
        with patch.object(provider, '_deliver_once', side_effect=provider._stopping.set), patch.object(provider, '_fetch_context') as fetch:
            provider._worker_loop()
        fetch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
