"""Actual ephemeral loopback tests; never contacts the dev gateway."""

import asyncio
import importlib.util
import os
from pathlib import Path
import socket
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_transport_relay.py"
spec = importlib.util.spec_from_file_location("memory_local_transport_relay", SCRIPT)
relay_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay_module)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name).resolve()
        self.directory.chmod(0o700)
        self.path = self.directory / "relay.sock"
        self.upstream_connections = 0
        self.upstream_writers = set()
        self.upstream_tasks = set()

        async def echo(reader, writer):
            task = asyncio.current_task()
            self.upstream_tasks.add(task)
            self.upstream_connections += 1
            self.upstream_writers.add(writer)
            try:
                while data := await reader.read(1024):
                    writer.write(data)
                    await writer.drain()
            except (ConnectionError, asyncio.CancelledError):
                pass
            finally:
                writer.close()
                try:
                    await writer.wait_closed()
                except ConnectionError:
                    pass
                self.upstream_writers.discard(writer)
                self.upstream_tasks.discard(task)

        self.upstream = await asyncio.start_server(echo, "127.0.0.1", 0)
        self.port = self.upstream.sockets[0].getsockname()[1]
        self.relays = []

    async def asyncTearDown(self):
        for relay in self.relays:
            await asyncio.wait_for(relay.close(), 4)
        self.upstream.close()
        for writer in list(self.upstream_writers):
            writer.close()
        if self.upstream_tasks:
            await asyncio.wait_for(asyncio.gather(*list(self.upstream_tasks)), 2)
        await asyncio.wait_for(self.upstream.wait_closed(), 2)
        self.temp.cleanup()

    async def start(self, **kwargs):
        relay = relay_module.Relay(self.path, listen_port=0, upstream_port=self.port, **kwargs)
        self.relays.append(relay)
        await relay.start()
        return relay

    async def connect(self, relay):
        return await asyncio.open_connection("127.0.0.1", relay.listen_port)

    async def assert_closed(self, reader):
        try:
            self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        except ConnectionResetError:
            pass

    async def test_offline_closes_inflight_rejects_new_and_online_restores_forwarding(self):
        relay = await self.start()
        reader, writer = await self.connect(relay)
        payload = b"opaque\x00bytes\xff\r\nAuthorization: synthetic-test-secret\r\n"
        writer.write(payload)
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(len(payload)), 1), payload)
        status = await relay_module.control_request(self.path, "offline")
        self.assertEqual(status["mode"], "offline")
        self.assertEqual(status["connections"], 0)
        await self.assert_closed(reader)
        count = self.upstream_connections
        blocked_reader, blocked_writer = await self.connect(relay)
        await self.assert_closed(blocked_reader)
        self.assertEqual(self.upstream_connections, count)
        blocked_writer.close()
        await blocked_writer.wait_closed()
        await relay_module.control_request(self.path, "online")
        fresh_reader, fresh_writer = await self.connect(relay)
        fresh_writer.write(b"restored")
        await fresh_writer.drain()
        self.assertEqual(await asyncio.wait_for(fresh_reader.readexactly(8), 1), b"restored")
        fresh_writer.close()
        await fresh_writer.wait_closed()
        writer.close()
        await writer.wait_closed()

    async def test_connection_limit_and_idle_timeout_bound_resources(self):
        relay = await self.start(max_connections=1, io_timeout=0.2)
        first_reader, first_writer = await self.connect(relay)
        first_writer.write(b"one")
        await first_writer.drain()
        self.assertEqual(await first_reader.readexactly(3), b"one")
        extra_reader, extra_writer = await self.connect(relay)
        await self.assert_closed(extra_reader)
        self.assertEqual(self.upstream_connections, 1)
        await self.assert_closed(first_reader)
        for writer in (first_writer, extra_writer):
            writer.close()
            await writer.wait_closed()

    async def test_status_and_invalid_control_requests_are_bounded_and_content_free(self):
        relay = await self.start()
        status = await relay_module.control_request(self.path, "status")
        self.assertEqual(set(status), {"mode", "connections", "listen_port", "upstream_port"})
        self.assertEqual(status["listen_port"], relay.listen_port)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        reader, writer = await asyncio.open_unix_connection(str(self.path))
        writer.write(b"private-unknown-payload" * 20 + b"\n")
        await writer.drain()
        self.assertEqual(await reader.readline(), b'{"error":"invalid_control_request"}\n')
        writer.close()
        await writer.wait_closed()
        self.assertEqual((await relay_module.control_request(self.path, "status"))["mode"], "online")
        with self.assertRaises(relay_module.RelayError):
            await relay_module.control_request(self.path, "arbitrary")

    async def test_existing_regular_file_symlink_or_socket_is_never_replaced(self):
        self.path.write_text("preserve")
        with self.assertRaisesRegex(relay_module.RelayError, "control_path_exists"):
            await self.start()
        self.assertEqual(self.path.read_text(), "preserve")
        self.path.unlink()
        target = self.directory / "target"
        target.write_text("preserve")
        self.path.symlink_to(target)
        with self.assertRaisesRegex(relay_module.RelayError, "control_path_exists"):
            await self.start()
        self.assertTrue(self.path.is_symlink())
        self.path.unlink()
        existing = socket.socket(socket.AF_UNIX)
        try:
            existing.bind(str(self.path))
            inode = self.path.lstat().st_ino
            with self.assertRaisesRegex(relay_module.RelayError, "control_path_exists"):
                await self.start()
            self.assertEqual(self.path.lstat().st_ino, inode)
        finally:
            existing.close()

    async def test_permissive_directory_and_symlink_ancestor_are_rejected(self):
        self.directory.chmod(0o755)
        with self.assertRaisesRegex(relay_module.RelayError, "private_control_directory_required"):
            await self.start()
        self.assertFalse(self.path.exists())
        self.directory.chmod(0o700)
        link = self.directory / "link"
        private = self.directory / "private"
        private.mkdir(mode=0o700)
        link.symlink_to(private, target_is_directory=True)
        relay = relay_module.Relay(link / "relay.sock", listen_port=0, upstream_port=self.port)
        self.relays.append(relay)
        with self.assertRaisesRegex(relay_module.RelayError, "control_parent_symlink"):
            await relay.start()
        self.assertFalse((private / "relay.sock").exists())

    async def test_shutdown_removes_only_its_own_socket(self):
        relay = await self.start()
        self.assertTrue(await relay.close())
        self.assertFalse(self.path.exists())
        self.relays.remove(relay)
        replacement = await self.start()
        self.path.unlink()
        self.path.write_text("new owner")
        self.assertFalse(await replacement.close())
        self.assertEqual(self.path.read_text(), "new owner")

    async def test_listener_failure_cleans_only_new_socket_and_leaves_other_listener_alive(self):
        relay = relay_module.Relay(self.path, listen_port=self.port, upstream_port=self.port)
        self.relays.append(relay)
        with self.assertRaisesRegex(relay_module.RelayError, "relay_start_failed"):
            await relay.start()
        self.assertFalse(self.path.exists())
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        writer.write(b"untouched")
        await writer.drain()
        self.assertEqual(await reader.readexactly(9), b"untouched")
        writer.close()
        await writer.wait_closed()

    async def test_offline_and_close_own_connections_even_before_payload_is_sent(self):
        relay = await self.start()
        clients = [await self.connect(relay) for _ in range(8)]
        await relay.set_mode("offline")
        self.assertEqual(relay.status()["connections"], 0)
        self.assertFalse(relay.writers)
        for reader, writer in clients:
            await self.assert_closed(reader)
            writer.close()
            await writer.wait_closed()
        control_reader, control_writer = await asyncio.open_unix_connection(str(self.path))
        await relay.close()
        await self.assert_closed(control_reader)
        self.assertFalse(relay.control_writers)
        control_writer.close()
        await control_writer.wait_closed()

    async def test_start_offline_never_contacts_upstream_until_explicit_online(self):
        relay = await self.start(mode="offline")
        reader, writer = await self.connect(relay)
        await self.assert_closed(reader)
        self.assertEqual(self.upstream_connections, 0)
        writer.close()
        await writer.wait_closed()

    async def test_close_immediately_after_tcp_or_unix_connect_has_no_loop_errors(self):
        loop = asyncio.get_running_loop()
        previous_handler = loop.get_exception_handler()
        failures = []

        def record_failure(loop, context):
            failures.append(context)
            loop.default_exception_handler(context)

        loop.set_exception_handler(record_failure)
        try:
            for transport in ("tcp", "unix"):
                with self.subTest(transport=transport):
                    relay = await self.start()
                    reader, writer = (await self.connect(relay) if transport == "tcp"
                                      else await asyncio.open_unix_connection(str(self.path)))
                    try:
                        await relay.close()
                        await self.assert_closed(reader)
                        self.assertFalse(relay.writers)
                        self.assertFalse(relay.control_writers)
                        self.assertFalse(relay.tcp_tasks)
                        self.assertFalse(relay.control_tasks)
                        self.assertEqual(failures, [])
                    finally:
                        writer.close()
                        await writer.wait_closed()
        finally:
            loop.set_exception_handler(previous_handler)


if __name__ == "__main__":
    unittest.main()
