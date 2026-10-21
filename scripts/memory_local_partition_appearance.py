#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Create one retained synthetic host through Admin and observe already-open pickers.

uv run scripts/memory_local_partition_appearance.py --fixture PATH
No memories, Settings, providers or services are changed. A stale picker is a
failed check, even when another page discovers the new empty partition.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import time
import urllib.parse
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SELECTION_KEYS = {"memory_space_id", "host", "client", "scope", "namespace"}
TOKEN = re.compile(r"bha_[A-Za-z0-9_-]+|\bBearer\s+[^\s\"'<>]+", re.IGNORECASE)


class CheckFailed(RuntimeError):
    """A fixed nonsecret check code."""


def require(value, code):
    if not value:
        raise CheckFailed(code)


def valid_run(run_id):
    require(isinstance(run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id")


def make_identity(run_id):
    valid_run(run_id)
    nonce = str(time.time_ns()) + "-" + uuid.uuid4().hex[:8]
    return {"name": "memory-local-" + run_id + "-appearance-" + nonce,
            "scope": "memory_local_" + run_id + "_appearance_" + nonce}


def load_fixture(path):
    with path.open("rb") as stream:
        raw = stream.read(1_000_001)
    require(len(raw) <= 1_000_000, "fixture_size")
    fixture = json.loads(raw)
    run_id = fixture["run_id"]
    valid_run(run_id)
    host = fixture["hosts"][0]
    partition = host["partition"]
    host_id = str(uuid.UUID(partition["host_id"]))
    require(host["name"] == "memory-local-" + run_id + "-primary" and host["host_id"] == host_id,
            "fixture_primary_host")
    require(partition["client_id"] == "host:" + host_id and partition["namespace"] == "private" and
            partition["scope"] == "memory_local_" + run_id + "_primary", "fixture_partition")
    return run_id, {"memory_space_id": str(uuid.UUID(partition["memory_space_id"])),
                    "host": host_id, "client": partition["client_id"],
                    "scope": partition["scope"], "namespace": "private"}


def validate_admin(url):
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1") and
            parsed.username is None and parsed.password is None and parsed.path in ("", "/") and
            not parsed.query and not parsed.fragment, "loopback_admin_url")
    return url.rstrip("/")


def query(url):
    return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query, keep_blank_values=True))


def validated_choice(href, base, identity):
    parsed = urllib.parse.urlsplit(urllib.parse.urljoin(base + "/", href))
    expected = urllib.parse.urlsplit(base)
    require(parsed.scheme == expected.scheme and parsed.netloc == expected.netloc and
            parsed.path in ("/memory/sessions", "/memory/memories") and not parsed.fragment,
            "choice_surface")
    pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    selected = dict(pairs)
    require(len(pairs) == len(selected) and set(selected) == SELECTION_KEYS, "choice_query")
    require(selected["host"] == identity["host_id"] and selected["client"] == "host:" + identity["host_id"] and
            selected["scope"] == identity["scope"] and selected["namespace"] == "private", "choice_partition")
    selected["memory_space_id"] = str(uuid.UUID(selected["memory_space_id"]))
    return selected


def redact(value):
    if isinstance(value, str):
        return TOKEN.sub("[REDACTED]", value)
    if isinstance(value, dict):
        return {redact(str(key)): redact(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(item) for item in value]
    return value


def evaluate_report(report):
    pages = {}
    for name in ("sessions", "memories"):
        row = report.get("pages", {}).get(name, {})
        elapsed = row.get("appearance_ms")
        found = bool(row.get("choice_href")) and row.get("choice_visible") is True
        preserved = bool(row.get("before")) and row.get("before") == row.get("after") and row.get("navigation_requests") == 0
        timely = isinstance(elapsed, int) and 0 <= elapsed <= 5000
        pages[name] = {"discovered": found, "state_preserved": preserved, "within_five_seconds": timely,
                       "passed": found and preserved and timely}
    empty = report.get("empty_partition", {})
    empty_passed = empty.get("selection_matches") is True and empty.get("count") == 0 and empty.get("empty_visible") is True
    return {"pages": pages, "empty_partition": empty_passed,
            "passed": report.get("creation", {}).get("confirmed") is True and
            all(row["passed"] for row in pages.values()) and empty_passed and
            report.get("page_error_count", 0) == 0 and "failure" not in report}


class Appearance:
    def __init__(self, fixture, admin_url, search):
        self.run_id, self.primary = load_fixture(fixture)
        self.base = validate_admin(admin_url)
        require(isinstance(search, str) and 0 < len(search) <= 100 and not TOKEN.search(search), "search_bound")
        self.search = search
        self.identity = make_identity(self.run_id)
        parent = ROOT / ".devenv/memory-local-evidence" / self.run_id
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.output = parent / ("partition-appearance-" + str(time.time_ns()))
        self.output.mkdir(mode=0o700)
        self.report = {"run_id": self.run_id, "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=5).strip(),
                       "evidence_level": "live-browser-new-partition-subset", "complete_L17": False,
                       "environment": "local-installed-chrome", "primary_selection": self.primary,
                       "creation": {**self.identity, "attempted": False, "confirmed": False, "retained": True},
                       "pages": {}, "page_error_count": 0,
                       "poll_bound_ms": 8000, "ui_budget_ms": 5000,
                       "unexercised": ["other Memory pages", "host connection", "capture or memory writes", "second full retained acceptance run"]}
        self.pages = {}

    def save(self):
        temporary = self.output / "report.tmp"
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
            json.dump(redact(self.report), stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        path = self.output / "report.json"
        temporary.replace(path)
        return path

    def watch(self, page):
        page.on("pageerror", lambda _: self.report.update(page_error_count=self.report["page_error_count"] + 1))

    def open(self, page, url):
        response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
        require(response is not None and response.status == 200, "admin_http_status")
        page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)

    def fixture_url(self, section, **extra):
        return self.base + "/memory/" + section + "?" + urllib.parse.urlencode({**self.primary, **extra})

    def snapshot(self, page, name):
        params = query(page.url)
        require(all(params.get(key) == value for key, value in self.primary.items()), "old_selection_lost")
        document = page.evaluate("""() => ({marker: document.__memoryPartitionAppearance ?? null,
            time_origin: performance.timeOrigin, liveview_id: document.querySelector('[data-phx-main]')?.id})""")
        require(document["marker"] is not None, "document_marker_lost")
        filters = {key: params[key] for key in ("q", "type", "session", "project", "offset") if key in params}
        selected = None
        detail = False
        if name == "memories":
            require(page.locator("#memories-error").count() == 0, "memory_query_failed")
            for key in ("q", "type", "session"):
                require(page.locator('[name="filters[' + key + ']"]').input_value() == params.get(key, ""), "old_filter_lost")
            selected = str(uuid.UUID(urllib.parse.urlsplit(page.url).path.rsplit("/", 1)[-1]))
            detail = page.locator("#memory-detail").count() == 1
            require(detail and params.get("q") == self.search and params.get("offset") == "25", "old_detail_precondition")
        else:
            require(page.locator("#sessions-error").count() == 0, "session_query_failed")
        return {"url": page.url, "document": document, "filters": filters,
                "selected_id": selected, "detail_visible": detail}

    def prepare(self, context):
        sessions = context.new_page()
        memories = context.new_page()
        self.pages = {"sessions": sessions, "memories": memories}
        for page in self.pages.values():
            self.watch(page)
        self.open(sessions, self.fixture_url("sessions"))
        first = sessions.locator('#memory-sessions-table tbody a[href*="/memory/sessions/"]').first
        require(first.count() == 1, "populated_sessions_required")
        session = urllib.parse.unquote(urllib.parse.urlsplit(first.get_attribute("href")).path.rsplit("/", 1)[-1])
        self.open(sessions, self.fixture_url("sessions", session=session, offset=0))
        self.open(memories, self.fixture_url("memories", q=self.search, offset=25))
        require(int(memories.locator("#memories-count").inner_text().split()[0]) > 25, "multi_page_fixture_required")
        first = memories.locator('#memory-memories-table tbody a[href*="/memory/memories/"]').first
        require(first.count() == 1, "filtered_second_page_memory_required")
        first.click()
        memories.locator("#memory-detail").wait_for(timeout=10000)
        for name, page in self.pages.items():
            page.locator("#memory-partition-picker > summary").click()
            page.evaluate("marker => { document.__memoryPartitionAppearance = marker; }", str(uuid.uuid4()))
            row = {"before": self.snapshot(page, name), "navigation_requests": 0,
                   "choice_href": None, "choice_visible": False, "appearance_ms": None,
                   "dom_present": False, "dom_discovery_ms": None, "picker_expansions": 0}
            self.report["pages"][name] = row
            page.on("request", lambda request, page=page, row=row: row.update(navigation_requests=row["navigation_requests"] + 1)
                    if request.is_navigation_request() and request.frame == page.main_frame else None)
        self.save()

    def register(self, context):
        page = context.new_page()
        self.watch(page)
        self.open(page, self.base + "/system/host-agents")
        require(page.locator("#host-agents-table tbody tr").filter(has_text=self.identity["name"]).count() == 0, "host_name_collision")
        page.locator("#open-agent-modal").click()
        page.locator("#agent-name").fill(self.identity["name"])
        page.locator("#agent-memory-scope").fill(self.identity["scope"])
        self.report["creation"]["attempted"] = True
        self.report["creation"]["submission_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.save()
        self.started = time.monotonic()
        # Exactly one submission. No HTML/body/response dumps, tracing, screenshots,
        # token reads or retries on this page, which displays the generated secret.
        page.locator('#host-agent-form button[type="submit"]').click()
        row = page.locator("#host-agents-table tbody tr").filter(has_text=self.identity["name"])
        row.wait_for(timeout=10000)
        href = row.locator('a[aria-label="View"]').get_attribute("href")
        match = re.fullmatch(r"/system/host-agents/([0-9a-f-]+)/overview", href or "")
        require(match is not None, "registered_host_link")
        self.identity["host_id"] = str(uuid.UUID(match[1]))
        self.report["creation"].update(host_id=self.identity["host_id"], confirmed=True,
                                      row_visible_ms=round((time.monotonic() - self.started) * 1000))
        self.save()
        page.close()

    def observe_choice(self, page, row, deadline):
        if row["choice_visible"] or time.monotonic() >= deadline:
            return
        picker = page.locator("#memory-partition-picker")
        link = picker.get_by_role("link", name=self.identity["name"], exact=True, include_hidden=True)
        if link.count() != 1:
            return
        if row.get("dom_discovery_ms") is None:
            row.update(dom_present=True, dom_discovery_ms=round((time.monotonic() - self.started) * 1000))
        href = link.get_attribute("href", timeout=500)
        selected = validated_choice(href, self.base, self.identity)
        require(selected["memory_space_id"] != self.primary["memory_space_id"], "new_space_not_isolated")
        row.update(choice_href=href, selection=selected)
        if picker.get_attribute("open", timeout=500) is None:
            remaining_ms = int((deadline - time.monotonic()) * 1000)
            if remaining_ms <= 0:
                return
            picker.locator(":scope > summary").click(timeout=min(500, remaining_ms))
            row["picker_expansions"] = row.get("picker_expansions", 0) + 1
        if link.is_visible():
            row.update(choice_visible=True, appearance_ms=round((time.monotonic() - self.started) * 1000))

    def poll(self):
        deadline = self.started + 8
        while time.monotonic() < deadline:
            for name, page in self.pages.items():
                self.observe_choice(page, self.report["pages"][name], deadline)
            if all(row["choice_visible"] for row in self.report["pages"].values()):
                break
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.1, remaining))
        for name, page in self.pages.items():
            row = self.report["pages"][name]
            row["after"] = self.snapshot(page, name)
            screenshot = self.output / (name + "-retained.png")
            page.locator(".admin-content").screenshot(path=str(screenshot), timeout=10000)
            os.chmod(screenshot, 0o600)
            row["screenshot"] = screenshot.name
        self.save()

    def inspect_empty(self, context):
        row = next((row for row in self.report["pages"].values() if row["choice_href"]), None)
        if row is None:
            self.report["empty_partition"] = {"failure": "no_discovered_href"}
            return
        page = context.new_page()
        self.watch(page)
        self.open(page, urllib.parse.urljoin(self.base + "/", row["choice_href"]))
        selected = validated_choice(page.url, self.base, self.identity)
        if urllib.parse.urlsplit(page.url).path == "/memory/sessions":
            page.locator("#sessions-empty").wait_for(timeout=5000)
        memories_url = self.base + "/memory/memories?" + urllib.parse.urlencode(selected)
        self.open(page, memories_url)
        page.locator("#memories-empty").wait_for(timeout=5000)
        count = int(page.locator("#memories-count").inner_text().split()[0])
        screenshot = self.output / "new-empty-partition.png"
        page.locator("#memory-memories").screenshot(path=str(screenshot), timeout=10000)
        os.chmod(screenshot, 0o600)
        self.report["empty_partition"] = {"discovered_href": row["choice_href"], "selection": selected,
            "url": page.url, "selection_matches": query(page.url) == selected,
            "count": count, "empty_visible": page.locator("#memories-empty").is_visible(),
            "screenshot": screenshot.name}

    def run(self):
        try:
            from playwright.sync_api import sync_playwright
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(channel="chrome", headless=True)
                try:
                    context = browser.new_context(viewport={"width": 1440, "height": 1000})
                    context.set_default_timeout(10000)
                    self.prepare(context)
                    self.register(context)
                    self.poll()
                    self.inspect_empty(context)
                    context.close()
                finally:
                    browser.close()
        except Exception as error:
            self.report["failure"] = str(error) if isinstance(error, CheckFailed) else type(error).__name__
        self.report["gates"] = evaluate_report(self.report)
        passed = self.report["gates"]["passed"]
        self.report["status"] = "passed-subset" if passed else "failed"
        print(self.save())
        return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--admin-url", default="http://127.0.0.1:4221")
    parser.add_argument("--search", default="e", help="nonempty filter with at least 26 fixture matches")
    args = parser.parse_args()
    return Appearance(args.fixture, args.admin_url, args.search).run()


if __name__ == "__main__":
    raise SystemExit(main())
