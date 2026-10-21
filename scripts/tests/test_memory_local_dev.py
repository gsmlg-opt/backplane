"""Unit safety tests; only synthetic Python processes are launched."""

import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_dev.py"


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class LifecycleSafetyTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "memory lifecycle harness is missing")
        spec = importlib.util.spec_from_file_location("memory_local_dev", SCRIPT)
        self.dev = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.dev)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state_dir = Path(self.temp.name) / "state"
        self.config = Path(self.temp.name) / "private.yaml"
        self.config.write_text("token: synthetic-secret-never-print\n")
        self.gateway_port = free_port()
        self.host_port = free_port()
        self.urls = {
            "public": f"http://127.0.0.1:{self.gateway_port}/",
            "admin": f"http://127.0.0.1:{self.gateway_port}/",
            "host": f"http://127.0.0.1:{self.host_port}/",
        }

    def command(self, port):
        return [sys.executable, "-u", "-m", "http.server", str(port), "--bind", "127.0.0.1"]

    def start(self, **kwargs):
        commands = {
            "gateway": self.command(self.gateway_port),
            "host": self.command(self.host_port),
        }
        with patch.object(self.dev, "build_commands", return_value=commands), patch.object(
            self.dev, "endpoints", return_value=self.urls
        ):
            return self.dev.start(self.state_dir, self.config, timeout=3, **kwargs)

    def unrelated(self):
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True
        )
        def cleanup():
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=2)

        self.addCleanup(cleanup)
        return child

    def test_process_birth_uses_high_resolution_os_identity(self):
        child = self.unrelated()
        identity = self.dev.process_identity(child.pid)
        self.assertTrue(identity["birth"].startswith(("proc:", "darwin:")))

    def test_dead_process_record_refuses_to_signal_and_retains_state(self):
        child = self.unrelated()
        identity = self.dev.process_identity(child.pid)
        child.terminate()
        child.wait(timeout=2)
        self.state_dir.mkdir()
        self.dev.write_state(self.state_dir, {
            "owner": self.dev.OWNER, "root": str(self.dev.ROOT), "uid": self.dev.os.getuid(),
            "processes": [{"name": "host", "pid": child.pid, **identity}],
        })
        with self.assertRaisesRegex(RuntimeError, "stale|ownership"):
            self.dev.stop(self.state_dir)
        self.assertTrue((self.state_dir / "state.json").exists())

    def test_supported_host_command_executes_task_in_owning_app(self):
        bin_dir = Path(self.temp.name) / "bin"
        bin_dir.mkdir()
        devenv = bin_dir / "devenv"
        devenv.write_text('#!/bin/sh\n[ "$1" = shell ] || exit 2\nshift\n[ "$1" = -- ] || exit 3\nshift\nexec "$@"\n')
        mix = bin_dir / "mix"
        mix.write_text(f"#!{sys.executable}\nimport os, json, sys\nprint(json.dumps([os.getcwd(), sys.argv[1:], os.getpid()]))\n")
        devenv.chmod(0o700)
        mix.chmod(0o700)
        commands = self.dev.build_commands(self.config)
        self.assertEqual(commands["gateway"], ["devenv", "up"])
        child = subprocess.Popen(commands["host"], cwd=self.dev.ROOT,
                                 env={**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]},
                                 stdout=subprocess.PIPE, text=True)
        output, _ = child.communicate(timeout=3)
        self.assertEqual(child.returncode, 0)
        directory, args, pid = json.loads(output)
        self.assertEqual(directory, str(self.dev.ROOT / "apps/backplane_host_agent"))
        self.assertEqual(args, ["agent.run"])
        self.assertEqual(pid, child.pid)

    def detached_host(self):
        marker = Path(self.temp.name) / "detached-pid"
        helper = (
            "import subprocess,time,pathlib; "
            f"child=subprocess.Popen({self.command(self.host_port)!r}); "
            f"pathlib.Path({str(marker)!r}).write_text(str(child.pid)); time.sleep(60)"
        )
        code = ("import subprocess,time; "
                f"subprocess.Popen({[sys.executable, '-c', helper]!r}, start_new_session=True); "
                "time.sleep(60)")
        commands = {"gateway": self.command(self.gateway_port),
                    "host": [sys.executable, "-c", code]}
        with patch.object(self.dev, "build_commands", return_value=commands), patch.object(
            self.dev, "endpoints", return_value=self.urls
        ):
            state = self.dev.start(self.state_dir, self.config, timeout=3)
        pid = int(marker.read_text())
        identity = self.dev.process_identity(pid)

        def cleanup():
            current = self.dev.process_identity(pid)
            if current is not None and all(current[key] == identity[key] for key in ("birth", "pgid", "uid")):
                os.killpg(identity["pgid"], signal.SIGKILL)
            for record in state["processes"]:
                if self.dev.owns(record):
                    os.killpg(record["pgid"], signal.SIGKILL)
                child = self.dev.CHILDREN.pop(record["pid"], None)
                if child is not None:
                    child.wait(timeout=2)

        self.addCleanup(cleanup)
        return state, pid

    def test_stop_cleans_detached_owned_group_and_preserves_unrelated_process(self):
        unrelated = self.unrelated()
        state, detached = self.detached_host()
        host = next(record for record in state["processes"] if record["name"] == "host")
        self.assertNotEqual(self.dev.process_identity(detached)["pgid"], host["pgid"])
        self.assertNotEqual(self.dev.process_identity(detached)["pgid"], detached)
        self.dev.stop(self.state_dir)
        self.assertIsNone(self.dev.process_identity(detached))
        self.assertFalse(self.dev.http_ready(self.urls["host"]))
        self.assertIsNone(unrelated.poll())
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_persisted_descendants_allow_cleanup_after_launcher_exit(self):
        state, detached = self.detached_host()
        host = next(record for record in state["processes"] if record["name"] == "host")
        self.assertIn(detached, [record["pid"] for record in host.get("descendants", [])])
        child = self.dev.CHILDREN[host["pid"]]
        child.terminate()
        child.wait(timeout=2)
        self.dev.stop(self.state_dir)
        self.assertIsNone(self.dev.process_identity(detached))

    def test_stale_descendant_identity_retains_state_without_signals(self):
        state, detached = self.detached_host()
        original = json.loads(json.dumps(state))
        host = next(record for record in state["processes"] if record["name"] == "host")
        self.assertTrue(host.get("descendants"))
        host["descendants"][0]["birth"] = "reused-pid"
        self.dev.write_state(self.state_dir, state)
        with patch.object(self.dev.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "ownership|stale"):
                self.dev.stop(self.state_dir)
            kill.assert_not_called()
        self.assertTrue((self.state_dir / "state.json").exists())
        self.dev.write_state(self.state_dir, original)
        self.dev.stop(self.state_dir)

    def test_remember_descendants_accepts_child_disappearing_after_identity_snapshot(self):
        root = {"name": "gateway", "pid": 101, "birth": "root-birth",
                "pgid": 101, "uid": os.getuid(), "ppid": 1}
        child = {"pid": 102, "birth": "child-birth", "pgid": 101,
                 "uid": os.getuid(), "ppid": 101}
        root["descendants"] = [child]
        for first_identity in (child, None):
            child_probes = 0

            def identity(pid):
                nonlocal child_probes
                if pid == root["pid"]:
                    return root
                self.assertEqual(pid, child["pid"], "gone child cannot authorize new descendants")
                child_probes += 1
                return first_identity if child_probes == 1 else None

            with self.subTest(first_identity=first_identity), patch.object(
                self.dev, "process_identity", side_effect=identity
            ), patch.object(self.dev.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout="101 1\n102 101\n103 102\n"
            )), patch.object(self.dev.os, "killpg") as kill:
                self.dev.remember_descendants(root)
                self.assertEqual(root["descendants"], [child])
                self.assertEqual(child_probes, 2)
                kill.assert_not_called()

    def test_remember_descendants_rejects_changed_live_child_identity(self):
        root = {"name": "gateway", "pid": 101, "birth": "root-birth",
                "pgid": 101, "uid": os.getuid(), "ppid": 1}
        child = {"pid": 102, "birth": "child-birth", "pgid": 101,
                 "uid": os.getuid(), "ppid": 101}
        root["descendants"] = [child]
        for field, value in (("birth", "replacement-birth"), ("pgid", 999), ("uid", -1)):
            current = {**child, field: value}
            with self.subTest(field=field), patch.object(
                self.dev, "process_identity", side_effect=lambda pid: root if pid == 101 else current
            ), patch.object(self.dev.subprocess, "run") as discover, patch.object(self.dev.os, "killpg") as kill:
                with self.assertRaisesRegex(RuntimeError, "ownership mismatch.*state retained"):
                    self.dev.remember_descendants(root)
                discover.assert_not_called()
                kill.assert_not_called()
                self.assertEqual(root["descendants"], [child])

    def test_service_stop_accepts_owned_exit_after_group_snapshot(self):
        state = self.start()
        self.addCleanup(lambda: self.dev.stop_records(state["processes"], allow_gone=True))
        host = next(record for record in state["processes"] if record["name"] == "host")
        gateway = next(record for record in state["processes"] if record["name"] == "gateway")
        child = self.dev.CHILDREN[host["pid"]]
        run = self.dev.subprocess.run
        snapshots = 0

        def exit_after_snapshot(args, **kwargs):
            nonlocal snapshots
            result = run(args, **kwargs)
            if args == ["ps", "-axo", "pid=,pgid=,stat="]:
                snapshots += 1
                # The host group is preflighted, then checked again for SIGTERM.
                if snapshots == 2:
                    self.assertIn(str(child.pid), result.stdout)
                    child.terminate()
                    child.wait(timeout=2)
            return result

        with patch.object(self.dev.subprocess, "run", side_effect=exit_after_snapshot):
            self.dev.service(self.state_dir, "host", "stop")
        recorded = self.dev.read_state(self.state_dir)
        self.assertTrue(next(p for p in recorded["processes"] if p["name"] == "host")["stopped"])
        self.assertTrue(self.dev.owns(gateway))
        self.assertIsNone(self.dev.process_identity(child.pid))

    def test_group_exit_after_validation_is_already_stopped(self):
        child = self.unrelated()
        record = {"pid": child.pid, **self.dev.process_identity(child.pid)}
        killpg = os.killpg

        def exit_before_signal(pgid, sig):
            child.terminate()
            child.wait(timeout=2)
            return killpg(pgid, sig)

        with patch.object(self.dev.os, "killpg", side_effect=exit_before_signal):
            self.dev.signal_owned_group(record["pgid"], [record], signal.SIGTERM)
        self.assertIsNone(self.dev.process_identity(child.pid))

    def test_group_refuses_unknown_or_changed_live_members_without_signal(self):
        child = self.unrelated()
        record = {"pid": child.pid, **self.dev.process_identity(child.pid)}
        for records in ([], [{**record, "birth": "reused-pid"}],
                        [{**record, "uid": -1}], [{**record, "pgid": -1}]):
            with self.subTest(records=records), patch.object(self.dev.os, "killpg") as kill:
                with self.assertRaisesRegex(RuntimeError, "ownership changed"):
                    self.dev.signal_owned_group(record["pgid"], records, signal.SIGTERM)
                kill.assert_not_called()
        self.assertIsNone(child.poll())

    def test_missing_identity_for_live_group_member_refuses_signal(self):
        child = self.unrelated()
        record = {"pid": child.pid, **self.dev.process_identity(child.pid)}
        with patch.object(self.dev, "process_identity", return_value=None), patch.object(self.dev.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "ownership changed"):
                self.dev.signal_owned_group(record["pgid"], [record], signal.SIGTERM)
            kill.assert_not_called()
        self.assertIsNone(child.poll())

    def test_missing_config_never_launches_a_process(self):
        with patch.object(self.dev.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "config.*exist"):
                self.dev.start(self.state_dir, self.config.with_name("missing.yaml"), timeout=1)
            launch.assert_not_called()
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_occupied_port_never_launches_a_process(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.host_port))
            listener.listen()
            with patch.object(self.dev, "endpoints", return_value=self.urls), patch.object(
                self.dev.subprocess, "Popen"
            ) as launch:
                with self.assertRaisesRegex(RuntimeError, "occupied"):
                    self.dev.start(self.state_dir, self.config, timeout=1)
                launch.assert_not_called()

    def test_duplicate_start_refuses_and_stop_preserves_unrelated_process(self):
        unrelated = self.unrelated()
        state = self.start()
        self.addCleanup(lambda: self.dev.stop(self.state_dir) if (self.state_dir / "state.json").exists() else None)
        self.assertEqual([p["name"] for p in state["processes"]], ["gateway", "host"])
        for process in state["processes"]:
            self.assertEqual(process["pid"], process["pgid"])
            self.assertTrue(process["started_at"])
        with self.assertRaisesRegex(RuntimeError, "already|state"):
            self.start()
        with patch.object(self.dev, "endpoints", return_value=self.urls):
            status = self.dev.status(self.state_dir)
        self.assertTrue(all(p["running"] for p in status["processes"]))
        self.assertTrue(all(status["http_ready"].values()))
        self.assertNotIn("synthetic-secret", json.dumps(status))
        self.dev.stop(self.state_dir)
        self.assertIsNone(unrelated.poll())
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_host_first_waits_for_host_before_gateway(self):
        state = self.start(host_first=True)
        try:
            self.assertEqual([p["name"] for p in state["processes"]], ["host", "gateway"])
        finally:
            self.dev.stop(self.state_dir)

    def test_host_only_owns_and_restarts_only_its_host_beside_existing_gateway(self):
        gateway = subprocess.Popen(self.command(self.gateway_port), stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: gateway.wait(timeout=2))
        self.addCleanup(lambda: gateway.terminate() if gateway.poll() is None else None)
        deadline = self.dev.time.monotonic() + 3
        while not self.dev.http_ready(self.urls["public"]):
            self.assertIsNone(gateway.poll())
            self.assertLess(self.dev.time.monotonic(), deadline)
            self.dev.time.sleep(0.02)
        gateway_identity = self.dev.process_identity(gateway.pid)

        state = self.start(host_only=True)
        self.addCleanup(lambda: self.dev.stop(self.state_dir)
                        if (self.state_dir / "state.json").exists() else None)
        self.assertEqual([record["name"] for record in state["processes"]], ["host"])
        self.assertEqual(state["urls"], {"host": self.urls["host"]})
        self.assertNotIn(str(gateway.pid), json.dumps(state["processes"]))
        with self.assertRaisesRegex(RuntimeError, "cannot safely restart"):
            self.dev.service(self.state_dir, "gateway", "restart")

        commands = {"gateway": self.command(self.gateway_port), "host": self.command(self.host_port)}
        with patch.object(self.dev, "build_commands", return_value=commands):
            restarted = self.dev.service(self.state_dir, "host", "restart", timeout=3)
        self.assertTrue(restarted["http_ready"]["host"])
        self.dev.stop(self.state_dir)
        self.assertEqual(self.dev.process_identity(gateway.pid), gateway_identity)
        self.assertTrue(self.dev.http_ready(self.urls["public"]))

    def test_host_only_rejects_host_first_without_launching(self):
        with patch.object(self.dev.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "host-only.*host-first"):
                self.start(host_only=True, host_first=True)
            launch.assert_not_called()
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_host_exit_during_gateway_start_cannot_report_success(self):
        original_ready = self.dev.http_ready
        stopped = False

        def ready(url):
            nonlocal stopped
            result = original_ready(url)
            if url == self.urls["public"] and result and not stopped:
                state = self.dev.read_state(self.state_dir)
                host = next(record for record in state["processes"] if record["name"] == "host")
                child = self.dev.CHILDREN[host["pid"]]
                child.terminate()
                child.wait(timeout=2)
                stopped = True
            return result

        def cleanup():
            if (self.state_dir / "state.json").exists():
                state = self.dev.read_state(self.state_dir)
                self.dev.stop_records(state["processes"], allow_gone=True)
                (self.state_dir / "state.json").unlink()

        self.addCleanup(cleanup)
        with patch.object(self.dev, "http_ready", side_effect=ready):
            with self.assertRaisesRegex(RuntimeError, "host.*exited"):
                self.start(host_first=True)
        self.assertFalse((self.state_dir / "state.json").exists())

    def test_service_outage_and_restart_preserves_host_and_unrelated_process(self):
        state = self.start()
        unrelated = self.unrelated()
        host = next(record for record in state["processes"] if record["name"] == "host")
        commands = {"gateway": self.command(self.gateway_port), "host": self.command(self.host_port)}
        try:
            self.dev.service(self.state_dir, "gateway", "stop")
            self.assertFalse(self.dev.http_ready(self.urls["public"]))
            self.assertTrue(self.dev.owns(host))
            with patch.object(self.dev, "build_commands", return_value=commands):
                restarted = self.dev.service(self.state_dir, "gateway", "start", timeout=3)
            self.assertTrue(all(record["running"] for record in restarted["processes"]))
            self.assertTrue(self.dev.owns(host))
            self.assertIsNone(unrelated.poll())
        finally:
            self.dev.stop(self.state_dir)

    def test_service_start_refuses_occupied_port_without_adopting_process(self):
        self.start()
        try:
            self.dev.service(self.state_dir, "gateway", "stop")
            with socket.socket() as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind(("127.0.0.1", self.gateway_port))
                listener.listen()
                with self.assertRaisesRegex(RuntimeError, "occupied"):
                    self.dev.service(self.state_dir, "gateway", "start", timeout=1)
            self.assertTrue(self.dev.http_ready(self.urls["host"]))
        finally:
            self.dev.stop(self.state_dir)

    def test_stopping_stack_with_intentionally_stopped_host_is_safe(self):
        self.start()
        self.addCleanup(lambda: self.dev.stop(self.state_dir) if (self.state_dir / "state.json").exists() else None)
        self.dev.service(self.state_dir, "host", "stop")
        self.assertTrue(self.dev.http_ready(self.urls["public"]))
        self.dev.stop(self.state_dir)
        self.assertFalse(self.dev.http_ready(self.urls["public"]))

    def test_reused_pid_record_refuses_before_signalling_any_process(self):
        state = self.start()
        original = json.loads(json.dumps(state))
        unrelated = self.unrelated()
        state["processes"][0]["pid"] = unrelated.pid
        state["processes"][0]["pgid"] = unrelated.pid
        state["processes"][0]["birth"] = "stale-original-process"
        self.dev.write_state(self.state_dir, state)
        try:
            with self.assertRaisesRegex(RuntimeError, "ownership|stale"):
                self.dev.stop(self.state_dir)
            self.assertIsNone(unrelated.poll())
            self.assertIsNotNone(self.dev.process_identity(original["processes"][1]["pid"]))
        finally:
            self.dev.write_state(self.state_dir, original)
            self.dev.stop(self.state_dir)

    def test_unowned_state_refuses_without_launching(self):
        self.state_dir.mkdir()
        (self.state_dir / "state.json").write_text('{"owner": "someone-else"}')
        with patch.object(self.dev.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "state|owner"):
                self.dev.start(self.state_dir, self.config, timeout=1)
            launch.assert_not_called()
        with self.assertRaisesRegex(RuntimeError, "state|owner"):
            self.dev.stop(self.state_dir)

    def test_timeout_cleans_only_started_processes_and_keeps_logs(self):
        unrelated = self.unrelated()
        commands = {"gateway": [sys.executable, "-u", "-c", "import time; print('fixture-started'); time.sleep(60)"], "host": self.command(self.host_port)}
        with patch.object(self.dev, "build_commands", return_value=commands), patch.object(
            self.dev, "endpoints", return_value=self.urls
        ):
            with self.assertRaisesRegex(RuntimeError, "readiness.*log"):
                self.dev.start(self.state_dir, self.config, timeout=0.3)
        self.assertIsNone(unrelated.poll())
        self.assertFalse((self.state_dir / "state.json").exists())
        logs = list(self.state_dir.glob("*/gateway.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn("fixture-started", logs[0].read_text())

    def test_partial_failure_stops_previously_ready_host(self):
        unrelated = self.unrelated()
        commands = {
            "host": self.command(self.host_port),
            "gateway": [sys.executable, "-c", "raise SystemExit(1)"],
        }
        with patch.object(self.dev, "build_commands", return_value=commands), patch.object(
            self.dev, "endpoints", return_value=self.urls
        ):
            with self.assertRaisesRegex(RuntimeError, "startup|readiness"):
                self.dev.start(self.state_dir, self.config, timeout=3, host_first=True)
        self.assertFalse(self.dev.http_ready(self.urls["host"]))
        self.assertFalse((self.state_dir / "state.json").exists())
        self.assertIsNone(unrelated.poll())


if __name__ == "__main__":
    unittest.main()
