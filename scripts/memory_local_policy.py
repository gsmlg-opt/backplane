#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0", "PyYAML==6.0.3"]
# ///
"""Qualify local capture policy and retained host reports on the owned oct20-a stack.

Only capture.enabled changes, while the host is stopped. The gateway stays alive.
Reports/screenshots contain allowlisted metadata, never the reported YAML or token.
An original-config recovery copy is private, outside the evidence directory, and
removed only after restoration. Run explicitly; this is an L09 subset, not L01–18.
"""

import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("policy_lifecycle", Path(__file__).with_name("memory_local_dev.py"))
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)
CENTRAL = ("memory.pipeline.enabled", "memory.session_summary.enabled",
           "memory.host_sync.enabled")
STAMP = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)"


class CheckFailed(RuntimeError):
    """Only fixed, nonsecret codes may be retained as errors."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def private_file(path):
    path = Path(path).absolute()
    info = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
            and info.st_uid == os.getuid() and not info.st_mode & 0o077 and info.st_nlink == 1,
            "private_regular_nonsymlink_file_required")
    return info


def private_read(path):
    info = private_file(path)
    require(info.st_size <= 1_000_000, "input_size_bound")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino), "input_identity_changed")
        return os.read(fd, 1_000_001)
    finally:
        os.close(fd)


def safe_directory(path, create=False):
    path = Path(path).absolute()
    require(path.is_relative_to(ROOT / ".devenv"), "private_devenv_path_required")
    for folder in reversed([path, *path.parents]):
        if not folder.is_relative_to(ROOT / ".devenv"):
            continue
        if create and not folder.exists():
            folder.mkdir(mode=0o700)
        info = folder.lstat()
        require(folder.resolve(strict=True) == folder and stat.S_ISDIR(info.st_mode)
                and info.st_uid == os.getuid() and not info.st_mode & 0o022, "unsafe_directory")
    return path


class UniqueLoader(yaml.SafeLoader):
    pass


UniqueLoader.yaml_implicit_resolvers = {
    key: [(tag, pattern) for tag, pattern in values if tag != "tag:yaml.org,2002:timestamp"]
    for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        require(isinstance(key, str) and key not in result, "duplicate_or_invalid_yaml_key")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor("tag:yaml.org,2002:map", unique_mapping)


def parse_yaml(raw):
    require(len(raw) <= 1_000_000, "yaml_size_bound")
    try:
        value = yaml.load(raw, Loader=UniqueLoader)
    except yaml.YAMLError:
        raise CheckFailed("yaml_invalid") from None
    require(isinstance(value, dict), "yaml_mapping_required")
    return value


def disabled_config(original):
    """Replace the single literal scalar, preserving every other byte."""
    text = original.decode("utf-8")
    before = parse_yaml(text)
    require(isinstance(before.get("capture"), dict) and before["capture"].get("enabled") is True,
            "capture_initially_enabled_required")
    root = yaml.compose(text, Loader=UniqueLoader)
    capture = next(value for key, value in root.value if key.value == "capture")
    require(isinstance(capture, yaml.MappingNode), "capture_mapping_required")
    enabled = next(value for key, value in capture.value if key.value == "enabled")
    require(text[enabled.start_mark.index:enabled.end_mark.index] == "true", "literal_capture_true_required")
    changed = (text[:enabled.start_mark.index] + "false" + text[enabled.end_mark.index:]).encode("utf-8")
    expected = copy.deepcopy(before)
    expected["capture"]["enabled"] = False
    require(parse_yaml(changed) == expected, "capture_only_change_required")
    return changed


class ConfigGuard:
    def __init__(self, path, backup):
        self.path, self.backup = Path(path), Path(backup)
        info = private_file(self.path)
        self.identity = info.st_dev, info.st_ino
        self.original = private_read(self.path)
        self.disabled = disabled_config(self.original)
        self.expected = self.original

    def check(self):
        info = private_file(self.path)
        require((info.st_dev, info.st_ino) == self.identity and private_read(self.path) == self.expected,
                "external_config_edit_refused")

    def save_backup(self):
        fd = os.open(self.backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(self.original)
            stream.flush()
            os.fsync(stream.fileno())

    def replace(self, content):
        self.check()
        require(content in (self.original, self.disabled), "unexpected_config_replacement")
        fd = os.open(self.path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            opened = os.fstat(fd)
            require((opened.st_dev, opened.st_ino) == self.identity and os.read(fd, 1_000_001) == self.expected,
                    "external_config_edit_refused")
            os.lseek(fd, 0, os.SEEK_SET)
            with os.fdopen(os.dup(fd), "wb") as stream:
                stream.write(content)
                stream.truncate()
                stream.flush()
                os.fsync(stream.fileno())
            self.expected = content
        finally:
            os.close(fd)
        self.check()

    def remove_backup(self):
        require(private_read(self.backup) == self.original, "recovery_copy_changed")
        self.backup.unlink()


def timestamp(value):
    require(isinstance(value, str) and re.fullmatch(STAMP, value), "reported_timestamp_required")
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def report_values(payload, local_text, negotiation_text, host_id):
    """Only this allowlist can leave the privately parsed reported YAML."""
    require(payload.get("agent", {}).get("host_id") == host_id, "reported_host_mismatch")
    capture, memory = payload.get("capture"), payload.get("memory")
    require(isinstance(capture, dict) and type(capture.get("enabled")) is bool and isinstance(memory, dict),
            "reported_policy_missing")
    applied = payload.get("local_settings_applied_at")
    timestamp(applied)
    received = re.findall(STAMP, local_text.split("Report received:")[-1])
    require(len(received) == 1 and applied in local_text, "reported_received_timestamp_required")
    timestamp(received[0])
    negotiation = payload.get("memory_negotiation")
    require(isinstance(negotiation, dict) and negotiation.get("selected") == "host_memory.v2",
            "reported_v2_negotiation_required")
    negotiated = negotiation.get("applied_at")
    timestamp(negotiated)
    require(negotiated in negotiation_text and "host_memory.v2" in negotiation_text,
            "negotiation_display_mismatch")
    return {"capture": {key: capture.get(key) for key in ("enabled", "inject_context", "upload_interval_ms")},
            "memory": {key: memory.get(key) for key in ("enabled", "bound_scope", "sync_interval_ms")},
            "host_sync": {key: (memory.get("host_sync") or {}).get(key)
                             for key in ("enabled", "development_plaintext", "sync_interval_ms")},
            "local_applied_at": applied, "report_received_at": received[0],
            "negotiation": {"selected": "host_memory.v2", "applied_at": negotiated}}


def validate_report(sample, baseline, enabled, stale=False, fresh_after=None):
    require(sample["central"] == baseline["central"], "central_settings_changed")
    require(sample["documents"] == baseline["documents"], "browser_document_or_url_changed")
    require(sample["stale"] is stale and sample["health_stale"] is stale, "report_staleness_mismatch")
    expected = copy.deepcopy(baseline["policy"])
    expected["capture"]["enabled"] = enabled
    for key in ("capture", "memory", "host_sync"):
        require(sample["policy"][key] == expected[key], "reported_local_policy_mismatch")
    policy = sample["policy"]
    require(timestamp(policy["report_received_at"]) >= timestamp(policy["local_applied_at"]),
            "report_precedes_local_apply")
    if fresh_after:
        for key in ("local_applied_at", "report_received_at"):
            require(timestamp(policy[key]) > timestamp(fresh_after["policy"][key]), "fresh_report_required")
        require(timestamp(policy["negotiation"]["applied_at"]) >
                timestamp(fresh_after["policy"]["negotiation"]["applied_at"]), "fresh_negotiation_required")
    if stale:
        require(policy["local_applied_at"] == baseline["policy"]["local_applied_at"]
                and policy["negotiation"] == baseline["policy"]["negotiation"], "retained_report_changed")


class PolicyUI:
    def __init__(self, context, admin, host_id):
        self.pages, self.documents = {}, {}
        for name, route in (("central", "/memory/config"),
                            ("config", f"/system/host-agents/{host_id}/config"),
                            ("health", f"/system/host-agents/{host_id}/sync")):
            page = context.new_page()
            page.set_default_timeout(5000)
            response = page.goto(admin + route, wait_until="domcontentloaded", timeout=15000)
            require(response is not None and response.status == 200, "admin_page_unavailable")
            page.locator("[data-phx-main].phx-connected").wait_for(timeout=10000)
            document = str(uuid.uuid4())
            page.evaluate("value => window.__memoryPolicyDocument = value", document)
            self.pages[name] = page
            self.documents[name] = {"url": admin + route, "document": document}
        self.host_id = host_id

    def snapshot(self):
        central, documents = {}, {}
        for name, page in self.pages.items():
            require(page.locator("[data-phx-main].phx-connected").count() == 1, "browser_liveview_disconnected")
            documents[name] = {"url": page.url, "document": page.evaluate("window.__memoryPolicyDocument")}
        require(documents == self.documents, "browser_document_or_url_changed")
        page = self.pages["central"]
        require("standalone YAML" in page.locator("#memory-config-policy").inner_text(), "central_local_policy_explanation_missing")
        for key in CENTRAL:
            form = page.locator("#memory-config-form-" + key.replace(".", "-"))
            row = page.locator("tr").filter(has=form)
            values = [row.locator("td").nth(index).locator("code").first.inner_text() for index in (1, 2)]
            require(all(value in ("nil", "true", "false") for value in values), "central_boolean_shape_required")
            central[key] = dict(zip(("configured", "effective"), values))
        page = self.pages["config"]
        payload = parse_yaml(page.locator("#reported-config-yaml").inner_text())
        policy = report_values(payload, page.locator("#host-local-settings-report").inner_text(),
                               page.locator("#host-memory-negotiation").inner_text(), self.host_id)
        health = self.pages["health"].locator("#host-memory-health").inner_text()
        return {"central": central, "policy": policy, "documents": documents,
                "stale": page.locator("#host-report-stale").count() == 1,
                "health_stale": "Last-known Memory report; stale" in health}

    def screenshots(self, output, phase):
        # Deliberately exclude #reported-config-yaml, which contains the full report.
        for name, selector in (("central", "#memory-config-policy"), ("config", "#host-local-settings-report"),
                               ("config", "#host-memory-negotiation"), ("health", "#host-memory-health")):
            path = output / (phase + selector.replace("#", "-") + ".png")
            self.pages[name].locator(selector).screenshot(path=str(path), timeout=5000)
            path.chmod(0o600)
        if self.pages["config"].locator("#host-report-stale").count():
            path = output / (phase + "-stale.png")
            self.pages["config"].locator("#host-report-stale").screenshot(path=str(path), timeout=5000)
            path.chmod(0o600)


class Effects:
    now = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)
    read_state = staticmethod(lifecycle.read_state)
    owns = staticmethod(lifecycle.owns)

    def host_service(self, state_dir, action, timeout):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/memory_local_dev.py"),
            "--state-dir", str(state_dir), "service", "host", action, "--timeout", str(timeout)],
            cwd=ROOT, capture_output=True, timeout=timeout + 20)
        require(result.returncode == 0, "owned_host_lifecycle_failed")

    def post(self, base, path, body, timeout):
        request = urllib.request.Request(base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            response = urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(100_001)
            require(len(raw) <= 100_000, "http_response_bound")
            return response.status, json.loads(raw)

    def canonical(self, runner, timeout):
        psql = shutil.which("psql") or str(ROOT / ".devenv/profile/bin/psql")
        command = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", runner.socket, "-d", "backplane_dev"]
        for key, value in (("space", runner.partition["memory_space_id"]),
                           ("disabled", runner.sessions["disabled"]), ("restored", runner.sessions["restored"])):
            command.extend(["-v", key + "=" + value])
        sql = """BEGIN READ ONLY;
SET LOCAL statement_timeout='4s';
SET LOCAL search_path=public;
SELECT json_build_object('database',current_database(),
 'disabled_ids',(SELECT coalesce(json_agg(id::text),'[]'::json) FROM
  (SELECT id FROM bpm_events WHERE memory_space_id=:'space'::uuid AND session_id=:'disabled' LIMIT 2) d),
 'restored_ids',(SELECT coalesce(json_agg(id::text),'[]'::json) FROM
  (SELECT id FROM bpm_events WHERE memory_space_id=:'space'::uuid AND session_id=:'restored' LIMIT 2) r));
COMMIT;
"""
        result = subprocess.run(command, input=sql, text=True, capture_output=True, timeout=timeout)
        require(result.returncode == 0 and len(result.stdout) < 2000, "canonical_read_only_query_failed")
        value = json.loads(result.stdout)
        require(value.get("database") == "backplane_dev" and all(isinstance(value.get(key), list)
                and all(valid_uuid(item) for item in value[key]) for key in ("disabled_ids", "restored_ids")),
                "canonical_query_shape_required")
        return value


class Runner:
    def __init__(self, fixture, state_dir, case_id, effects=None, socket="/tmp/devenv-e733526/postgres"):
        self.fixture_path, self.state_dir = Path(fixture).absolute(), Path(state_dir).absolute()
        self.case_id, self.socket, self.fx = case_id, socket, effects or Effects()
        self.started, self.deadline = self.fx.now(), self.fx.now() + 300
        self.guard, self.output, self.ui = None, None, None
        self.armed = False
        self.report = {"status": "failed", "evidence_level": "local-dev-browser-owned-host-capture-policy",
            "complete_L01_L18": False, "phases": [], "cleanup": {"attempted": False, "verified": False},
            "limits": ["L09 host reporting/capture subset; no new model-readiness qualification",
                       "No V1/V2 flags, central settings, providers or gateway lifecycle changed",
                       "No L16, cross-machine or production protected-storage qualification"]}

    def bound(self, maximum=8):
        remaining = self.deadline - self.fx.now()
        require(remaining > 0, "scenario_deadline_exceeded")
        return min(maximum, remaining)

    def save(self):
        if self.output:
            path = self.output / "report.json"
            fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(self.report, stream, indent=2)

    def record(self, phase, **safe):
        self.report["phases"].append({"phase": phase, "elapsed_ms": round((self.fx.now() - self.started) * 1000), **safe})
        self.save()

    def stack(self, running=None):
        private_file(self.state_dir / "state.json")
        state = self.fx.read_state(self.state_dir)
        require(Path(state["config"]).absolute() == self.config and state["urls"] == self.urls,
                "fixture_lifecycle_mismatch")
        rows = {item["name"]: item for item in state["processes"]}
        require(len(state["processes"]) == 2 and set(rows) == {"gateway", "host"}, "owned_stack_required")
        gateway = rows["gateway"]
        require(not gateway.get("stopped") and self.fx.owns(gateway), "owned_gateway_required")
        identity = {key: gateway.get(key) for key in ("pid", "pgid", "uid", "birth")}
        require(identity == self.gateway, "gateway_identity_changed")
        host = rows["host"]
        if not host.get("stopped"):
            require(self.fx.owns(host), "owned_host_required")
        if running is not None:
            require(bool(host.get("stopped")) != running, "host_running_state_mismatch")
        return host

    def preflight(self):
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", self.case_id or ""), "case_id_invalid")
        expected = ROOT / ".devenv/memory-local-fixtures/oct20-a/fixture.json"
        require(self.fixture_path == expected, "oct20_a_fixture_only")
        safe_directory(self.fixture_path.parent)
        safe_directory(self.state_dir)
        fixture = json.loads(private_read(self.fixture_path))
        require(fixture.get("run_id") == "oct20-a" and isinstance(fixture.get("hosts"), list)
                and len(fixture["hosts"]) == 2, "synthetic_fixture_required")
        primary = fixture["hosts"][0]
        self.partition = primary["partition"]
        require(primary.get("name") == "memory-local-oct20-a-primary"
                and valid_uuid(primary.get("host_id")) and self.partition.get("host_id") == primary["host_id"]
                and valid_uuid(self.partition.get("memory_space_id"))
                and self.partition.get("client_id") == "host:" + primary["host_id"]
                and self.partition.get("scope") == "memory_local_oct20-a_primary"
                and self.partition.get("namespace") == "private", "fixture_partition_not_owned")
        self.config = expected.parent / "primary/host.yaml"
        require(Path(primary["config"]) == self.config, "fixture_config_binding_required")
        safe_directory(self.config.parent)
        private_file(self.state_dir / "state.json")
        state = self.fx.read_state(self.state_dir)
        self.urls = {"public": "http://127.0.0.1:4220/", "admin": "http://127.0.0.1:4221/",
                     "host": "http://127.0.0.1:4222/"}
        gateway = next(row for row in state["processes"] if row["name"] == "gateway")
        self.gateway = {key: gateway.get(key) for key in ("pid", "pgid", "uid", "birth")}
        self.stack(running=True)
        self.host_url = self.urls["host"].rstrip("/")
        require(re.fullmatch(r"/tmp/devenv-[a-zA-Z0-9_-]+/postgres", self.socket), "local_postgres_socket_required")
        backup = self.state_dir / ("capture-policy-" + self.case_id + ".yaml.private")
        require(not backup.exists() and not backup.is_symlink(), "existing_recovery_copy_refused")
        self.guard = ConfigGuard(self.config, backup)
        config = parse_yaml(self.guard.original)
        agent, memory, capture = (config.get(key, {}) for key in ("agent", "memory", "capture"))
        hub = urllib.parse.urlsplit(agent.get("hub_url", ""))
        require(agent.get("host_id") == primary["host_id"] and agent.get("machine_name") == primary["name"]
                and agent.get("http_bind") == "127.0.0.1" and agent.get("http_port") == 4222
                and hub.scheme == "http" and hub.hostname in ("localhost", "127.0.0.1") and hub.port == 4220
                and not hub.username and not hub.password and hub.path in ("", "/") and not hub.query and not hub.fragment
                and memory.get("enabled") is True and memory.get("bound_scope") == self.partition["scope"]
                and memory.get("host_sync", {}).get("enabled") is True
                and memory["host_sync"].get("development_plaintext") is True,
                "local_fixture_configuration_required")
        stores = [memory.get("db_path"), capture.get("db_path"), memory["host_sync"].get("db_path")]
        require(stores == [str(self.config.parent / name) for name in ("commands.db", "capture-spool.db", "mirror.db")]
                and len({(info.st_dev, info.st_ino) for info in map(private_file, stores)}) == 3,
                "three_distinct_fixture_stores_required")
        self.expected_local = {"capture": {key: capture.get(key) for key in ("enabled", "inject_context", "upload_interval_ms")},
            "memory": {key: memory.get(key) for key in ("enabled", "bound_scope", "sync_interval_ms")},
            "host_sync": {key: memory["host_sync"].get(key) for key in ("enabled", "development_plaintext", "sync_interval_ms")}}
        self.sessions = {phase: "memory-local-oct20-a-policy-" + self.case_id + "-" + phase for phase in ("disabled", "restored")}
        canonical = self.fx.canonical(self, self.bound(10))
        require(canonical["disabled_ids"] == [] and canonical["restored_ids"] == [], "fresh_case_id_required")
        folder = safe_directory(ROOT / ".devenv/memory-local-evidence/oct20-a", create=True)
        self.output = folder / ("capture-policy-" + self.case_id + "-" + str(time.time_ns()))
        self.output.mkdir(mode=0o700)
        self.report.update(case_id=self.case_id, host_id=primary["host_id"],
            memory_space_id=self.partition["memory_space_id"], original_yaml_sha256=hashlib.sha256(self.guard.original).hexdigest())
        self.record("preflight", owned_gateway_unchanged=True, synthetic_fixture_verified=True)

    def wait(self, operation, code, seconds=45):
        deadline = min(self.deadline, self.fx.now() + seconds)
        while self.fx.now() < deadline:
            try:
                return operation()
            except CheckFailed as error:
                if str(error) in ("browser_document_or_url_changed", "central_settings_changed"):
                    raise
            self.fx.sleep(min(0.25, max(0, deadline - self.fx.now())))
        raise CheckFailed(code)

    def sample(self, phase, enabled=True, stale=False, after=None):
        def check():
            sample = self.ui.snapshot()
            validate_report(sample, self.baseline, enabled, stale, after)
            return sample
        sample = self.wait(check, phase + "_report_timeout")
        self.ui.screenshots(self.output, phase)
        self.record(phase, **sample)
        return sample

    def service(self, action):
        self.guard.check()
        self.stack()
        require(self.bound(60) > 25, "lifecycle_cleanup_headroom_required")
        self.fx.host_service(self.state_dir, action, min(45, self.bound(60) - 20))
        self.stack(running=action == "start")
        self.record("host_" + action, gateway_unchanged=True)

    def hook_body(self, phase):
        return {"hook_event_name": "SessionStart", "session_id": self.sessions[phase],
            "agent_id": "memory-local-oct20-a", "cwd": "/synthetic/backplane-memory/oct20-a",
            "scope": self.partition["scope"], "occurred_at": self.occurred_at,
            "source_event_id": self.sessions[phase] + ":SessionStart", "source": "startup"}

    def capture(self, phase, expected):
        status, reply = self.fx.post(self.host_url, "/capture/v1/hooks/codex/SessionStart",
                                    self.hook_body(phase), self.bound())
        if expected == "unavailable":
            require(status == 503 and reply == {"ok": False, "error": "capture persistence unavailable"},
                    "disabled_capture_behavior_wrong")
            receipt = {"http_status": status, "status": "capture_persistence_unavailable"}
        else:
            require(status == 202 and reply.get("ok") is True and reply.get("status") == expected
                    and valid_uuid(reply.get("event_id")), "restored_capture_behavior_wrong")
            receipt = {"http_status": status, "status": expected, "event_id": reply["event_id"]}
        self.record(phase + "_capture", **receipt)
        return receipt.get("event_id")

    def restore_host(self):
        previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        try:
            for number in previous:
                signal.signal(number, signal.SIG_IGN)
            return self._restore_host()
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)

    def _restore_host(self):
        self.report["cleanup"]["attempted"] = True
        self.deadline = self.fx.now() + 180
        self.guard.check()
        if not self.stack().get("stopped"):
            self.service("stop")
        self.stack(running=False)
        self.guard.replace(self.guard.original)
        self.service("start")
        restored = self.sample("restored_report", after=self.baseline)
        self.guard.check()
        require(hashlib.sha256(private_read(self.config)).hexdigest() == self.report["original_yaml_sha256"],
                "original_yaml_hash_not_restored")
        self.report["cleanup"].update(verified=True, original_yaml_sha256=self.report["original_yaml_sha256"],
                                      gateway_unchanged=True, host_running=True)
        self.guard.remove_backup()
        return restored

    def execute(self, ui):
        self.ui = ui
        self.occurred_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            self.baseline = ui.snapshot()
            require(all(self.baseline["policy"][key] == value for key, value in self.expected_local.items()),
                    "baseline_report_does_not_match_local_config")
            validate_report(self.baseline, self.baseline, True)
            self.record("baseline", **self.baseline)
            ui.screenshots(self.output, "baseline")
            self.guard.save_backup()
            self.armed = True
            try:
                self.service("stop")
                stopped = self.sample("stopped_report", stale=True)
                self.fx.sleep(0.25)
                require(self.ui.snapshot() == stopped, "disconnected_report_not_stable")
                self.stack(running=False)
                self.guard.replace(self.guard.disabled)
                self.service("start")
                self.disabled = self.sample("disabled_report", enabled=False, after=stopped)
                self.capture("disabled", "unavailable")
                require(self.fx.canonical(self, self.bound(10))["disabled_ids"] == [], "disabled_capture_became_canonical")
                self.record("disabled_marker_absent", canonical_count=0)
            finally:
                self.restore_host()
            require(self.fx.canonical(self, self.bound(10))["disabled_ids"] == [], "disabled_marker_resurrected")
            accepted = self.capture("restored", "accepted")
            require(self.capture("restored", "duplicate") == accepted, "duplicate_capture_id_changed")
            def acknowledged():
                status, reply = self.fx.post(self.host_url, "/memory/diagnostics", {
                    "partition": {key: self.partition[key] for key in ("memory_space_id", "scope", "namespace")},
                    "command_ids": [], "event_ids": [accepted], "mirror_ids": []}, self.bound())
                result = reply.get("result", {})
                rows = result.get("capture", {}).get("rows", [])
                require(status == 200 and reply.get("ok") is True and result.get("observation_source") == "owner_connection"
                        and result.get("capture", {}).get("missing_or_compacted") == 0 and len(rows) == 1
                        and rows[0].get("event_id") == accepted and rows[0].get("acknowledged") is True
                        and rows[0].get("state") == "acknowledged", "restored_capture_not_acknowledged")
                canonical = self.fx.canonical(self, self.bound(10))
                require(canonical["disabled_ids"] == [] and canonical["restored_ids"] == [accepted],
                        "canonical_capture_not_exactly_once")
                return accepted
            self.wait(acknowledged, "restored_capture_ack_timeout", seconds=60)
            self.stack(running=True)
            self.record("restored_capture_acknowledged", event_id=accepted, canonical_count=1,
                        disabled_canonical_count=0, observation_source="owner_connection")
            self.report["status"] = "passed-host-capture-policy-subset"
        except (Exception, KeyboardInterrupt) as error:
            self.report["error"] = str(error) if isinstance(error, CheckFailed) else "policy_probe_failed"
            if self.armed and not self.report["cleanup"]["verified"]:
                self.report["cleanup"].update(error="RESTORATION_NOT_PROVEN", recovery_copy=str(self.guard.backup))
        finally:
            self.save()
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=ROOT / ".devenv/memory-local-fixtures/oct20-a/fixture.json")
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".devenv/memory-local")
    parser.add_argument("--case-id", required=True, help="unique synthetic case ID; do not reuse a completed case")
    parser.add_argument("--socket", default="/tmp/devenv-e733526/postgres")
    args = parser.parse_args()
    runner = Runner(args.fixture, args.state_dir, args.case_id, socket=args.socket)
    def interrupted(_number, _frame):
        raise CheckFailed("interrupted")
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    try:
        runner.preflight()
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless=True)
            try:
                context = browser.new_context(viewport={"width": 1440, "height": 1000})
                errors = []
                context.on("page", lambda page: page.on("pageerror", lambda _error: errors.append("page_error")))
                ui = PolicyUI(context, runner.urls["admin"].rstrip("/"), runner.partition["host_id"])
                runner.execute(ui)
                runner.report["page_errors"] = len(errors)
                if errors:
                    runner.report.update(status="failed", error="browser_page_error")
            finally:
                browser.close()
    except (Exception, KeyboardInterrupt) as error:
        runner.report.update(status="failed", error=str(error) if isinstance(error, CheckFailed)
                             else "policy_preflight_or_browser_failed")
    finally:
        runner.save()
    print(json.dumps({"status": runner.report["status"], "report": str(runner.output / "report.json") if runner.output else None,
                      "cleanup": runner.report["cleanup"], "error": runner.report.get("error")}))
    return 0 if runner.report["status"] == "passed-host-capture-policy-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
