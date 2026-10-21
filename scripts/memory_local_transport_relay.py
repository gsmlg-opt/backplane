#!/usr/bin/env python3
"""Foreground loopback fault relay; forwards opaque bytes without logging them.

Serve 127.0.0.1:4224 -> 127.0.0.1:4220. The control socket's existing parent
must be owned by this user, private, and reached without symlinks. Nothing is
unlinked on startup. The parent process owns this foreground process's lifetime.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import stat
import sys

LISTEN_PORT = 4224
UPSTREAM_PORT = 4220
STREAM_LIMIT = 65536
CHUNK_SIZE = 16384
CONTROL_LIMIT = 128
CONTROL_TIMEOUT = 2


class RelayError(RuntimeError):
    """Fixed content-free failure code."""


def control_parent(path):
    path = Path(path)
    if not path.is_absolute() or path.name in ("", ".", "..") or ".." in path.parts:
        raise RelayError("absolute_control_path_required")
    try:
        for parent in reversed(path.parents):
            info = parent.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise RelayError("control_parent_symlink")
            if not stat.S_ISDIR(info.st_mode):
                raise RelayError("control_parent_directory_required")
        info = path.parent.lstat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise RelayError("private_control_directory_required")
    except OSError:
        raise RelayError("control_parent_unavailable") from None
    return path


def socket_identity(path):
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise RelayError("owned_control_socket_required")
    return info.st_dev, info.st_ino, info.st_uid


async def close_writers(writers):
    for writer in writers:
        writer.transport.abort()

    async def closed(writer):
        try:
            await asyncio.wait_for(writer.wait_closed(), 1)
        except (OSError, asyncio.TimeoutError):
            pass

    await asyncio.gather(*(closed(writer) for writer in writers))


class Relay:
    """Ports are injectable only for ephemeral loopback tests; CLI ports are fixed."""

    def __init__(self, control_path, *, listen_port=LISTEN_PORT, upstream_port=UPSTREAM_PORT,
                 max_connections=32, io_timeout=300, mode="online"):
        if (type(listen_port) is not int or not 0 <= listen_port <= 65535
                or type(upstream_port) is not int or not 1 <= upstream_port <= 65535
                or type(max_connections) is not int or not 1 <= max_connections <= 128
                or not 0.01 <= io_timeout <= 600 or mode not in ("online", "offline")):
            raise RelayError("invalid_relay_options")
        self.path = Path(control_path)
        self.listen_port, self.upstream_port = listen_port, upstream_port
        self.max_connections, self.io_timeout, self.mode = max_connections, io_timeout, mode
        self.tcp_server = self.control_server = None
        self.identity = None
        self.tcp_tasks, self.control_tasks, self.writers = set(), set(), set()
        self.control_writers = set()
        self.mode_lock = asyncio.Lock()
        self.closing = False

    async def start(self):
        control_parent(self.path)
        if os.path.lexists(self.path):
            raise RelayError("control_path_exists")
        control_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            # bind refuses existing paths, including a path appearing after the check.
            control_socket.bind(str(self.path))
            self.identity = socket_identity(self.path)
            self.path.chmod(0o600)
            control_socket.setblocking(False)
            # Newer asyncio otherwise removes the pathname before our inode/UID guard.
            options = {"cleanup_socket": False} if sys.version_info >= (3, 13) else {}
            self.control_server = await asyncio.start_unix_server(
                self.accept_control, sock=control_socket, limit=CONTROL_LIMIT, **options)
            self.tcp_server = await asyncio.start_server(
                self.accept_tcp, "127.0.0.1", self.listen_port, limit=STREAM_LIMIT,
                backlog=self.max_connections)
            self.listen_port = self.tcp_server.sockets[0].getsockname()[1]
        except Exception:
            if self.control_server is None:
                control_socket.close()
            await self.close()
            raise RelayError("relay_start_failed") from None
        return self.status()

    def status(self):
        return {"mode": self.mode, "connections": sum(not task.done() for task in self.tcp_tasks),
                "listen_port": self.listen_port, "upstream_port": self.upstream_port}

    def accept_tcp(self, reader, writer):
        if self.closing or self.mode == "offline" or len(self.tcp_tasks) >= self.max_connections:
            writer.transport.abort()
            return
        # Register synchronously: offline may cancel a task before its body starts.
        self.writers.add(writer)
        task = asyncio.create_task(self.forward(reader, writer))
        self.tcp_tasks.add(task)
        task.add_done_callback(self.tcp_tasks.discard)

    async def forward(self, reader, writer):
        owned = {writer}
        pumps = []
        try:
            upstream_reader, upstream_writer = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", self.upstream_port, limit=STREAM_LIMIT), 3)
            owned.add(upstream_writer)
            self.writers.add(upstream_writer)
            if self.mode != "online" or self.closing:
                return
            pumps = [asyncio.create_task(self.pipe(reader, upstream_writer)),
                     asyncio.create_task(self.pipe(upstream_reader, writer))]
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except Exception:
            # Transport failures close the pair; never retain an exception or raw bytes.
            pass
        finally:
            for task in pumps:
                task.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            await close_writers(owned)
            self.writers.difference_update(owned)

    async def pipe(self, reader, writer):
        while data := await asyncio.wait_for(reader.read(CHUNK_SIZE), self.io_timeout):
            writer.write(data)
            await asyncio.wait_for(writer.drain(), 3)

    async def set_mode(self, mode):
        async with self.mode_lock:
            if mode not in ("online", "offline") or self.closing:
                raise RelayError("invalid_mode")
            self.mode = mode
            if mode == "offline":
                await self.close_connections()
            return self.status()

    async def close_connections(self):
        tasks = list(self.tcp_tasks)
        for task in tasks:
            task.cancel()
        await close_writers(list(self.writers))
        if tasks:
            await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), 2)
        self.writers.clear()

    def accept_control(self, reader, writer):
        if self.closing or len(self.control_tasks) >= 8:
            writer.transport.abort()
            return
        self.control_writers.add(writer)
        task = asyncio.create_task(self.control(reader, writer))
        self.control_tasks.add(task)
        task.add_done_callback(self.control_tasks.discard)

    async def control(self, reader, writer):
        try:
            raw = await asyncio.wait_for(reader.readline(), CONTROL_TIMEOUT)
            if len(raw) > CONTROL_LIMIT or not raw.endswith(b"\n"):
                raise RelayError("invalid_control_request")
            request = json.loads(raw)
            if (not isinstance(request, dict) or set(request) != {"action"}
                    or request["action"] not in ("status", "online", "offline")):
                raise RelayError("invalid_control_request")
            result = self.status() if request["action"] == "status" else await self.set_mode(request["action"])
        except Exception:
            result = {"error": "invalid_control_request"}
        try:
            writer.write(json.dumps(result, separators=(",", ":")).encode() + b"\n")
            await asyncio.wait_for(writer.drain(), CONTROL_TIMEOUT)
        except Exception:
            pass
        finally:
            await close_writers([writer])
            self.control_writers.discard(writer)

    async def close(self):
        self.closing, self.mode = True, "offline"
        # On the Unix selector loop, accept() queues transport creation for the
        # next turn. Stop accepting first, then let those transports attach before
        # Server.close() invalidates the server. Their callbacks see closing and
        # abort; closing the listener immediately can orphan an accepted socket.
        loop = asyncio.get_running_loop()
        for server in (self.tcp_server, self.control_server):
            if server is not None:
                for listener in server.sockets:
                    loop.remove_reader(listener.fileno())
        await asyncio.sleep(0)
        for server in (self.tcp_server, self.control_server):
            if server is not None:
                server.close()
        await self.close_connections()
        tasks = list(self.control_tasks)
        for task in tasks:
            task.cancel()
        await close_writers(list(self.control_writers))
        if tasks:
            await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), 2)
        self.control_writers.clear()
        for server in (self.tcp_server, self.control_server):
            if server is not None:
                await asyncio.wait_for(server.wait_closed(), 2)
        if self.identity is not None:
            try:
                control_parent(self.path)
                if socket_identity(self.path) == self.identity:
                    self.path.unlink()
                    self.identity = None
                    return True
            except (OSError, RelayError):
                pass
        return False


async def control_request(path, action):
    path = control_parent(path)
    if action not in ("status", "online", "offline"):
        raise RelayError("invalid_control_action")
    try:
        socket_identity(path)
        if stat.S_IMODE(path.lstat().st_mode) != 0o600:
            raise RelayError("private_control_socket_required")
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(str(path), limit=1024), CONTROL_TIMEOUT)
        try:
            writer.write(json.dumps({"action": action}).encode() + b"\n")
            await asyncio.wait_for(writer.drain(), CONTROL_TIMEOUT)
            raw = await asyncio.wait_for(reader.readline(), CONTROL_TIMEOUT)
            result = json.loads(raw)
            if (len(raw) > 1024 or not isinstance(result, dict)
                    or set(result) != {"mode", "connections", "listen_port", "upstream_port"}
                    or result["mode"] not in ("online", "offline")
                    or type(result["connections"]) is not int or not 0 <= result["connections"] <= 128
                    or any(type(result[key]) is not int or not 1 <= result[key] <= 65535
                           for key in ("listen_port", "upstream_port"))):
                raise RelayError("invalid_control_response")
            return result
        finally:
            await close_writers([writer])
    except Exception:
        raise RelayError("control_request_failed") from None


async def execute(args):
    if args.command != "serve":
        print(json.dumps(await control_request(args.control, args.command)), flush=True)
        return
    relay = Relay(args.control, mode=args.mode)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stopped.set)
    try:
        print(json.dumps(await relay.start()), flush=True)
        await stopped.wait()
    finally:
        removed = await relay.close()
        print(json.dumps({"status": "stopped", "control_socket_removed": removed}), flush=True)
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(signum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("serve", "status", "online", "offline"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--control", required=True, type=Path)
        if command == "serve":
            subparser.add_argument("--mode", choices=("online", "offline"), default="online")
    args = parser.parse_args()
    try:
        asyncio.run(execute(args))
        return 0
    except (RelayError, OSError):
        print(json.dumps({"error": "relay_operation_failed"}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
