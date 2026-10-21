#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Observe read-only Memory UI edges with installed Chrome; uv run this-file --fixture PATH.

No hosts, settings, or services are modified. Browser network isolation and a close
of this browser's own LiveView transport exercise retained-page reconnection.
This subset does not qualify all L17 cases.
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


class CheckFailed(RuntimeError):
    """Fixed nonsecret check code, never raw application or browser messages."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def selection(partition):
    return {"memory_space_id": str(uuid.UUID(partition["memory_space_id"])),
            "host": str(uuid.UUID(partition["host_id"])), "client": partition["client_id"],
            "scope": partition["scope"], "namespace": partition["namespace"]}


def query(url):
    return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query, keep_blank_values=True))


class Edges:
    def __init__(self, fixture, admin_url, search):
        fixture = json.loads(fixture.read_text())
        self.run_id = fixture["run_id"]
        require(bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", self.run_id)), "fixture_run_id")
        require(len(fixture["hosts"]) >= 2, "isolated_fixture_required")
        self.primary, self.isolated = [selection(host["partition"]) for host in fixture["hosts"][:2]]
        require(self.primary != self.isolated, "isolated_fixture_distinct")
        parsed = urllib.parse.urlsplit(admin_url)
        require(parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1") and
                parsed.username is None and parsed.password is None and not parsed.query and
                not parsed.fragment and parsed.path in ("", "/"), "loopback_admin_url")
        self.base = admin_url.rstrip("/")
        # Generated facts need not retain the capture marker. A broad nonempty
        # text filter lets the actual fixture count establish pagination readiness.
        self.search = search or "e"
        require(0 < len(self.search) <= 100, "search_bound")
        parent = ROOT / ".devenv/memory-local-evidence" / self.run_id
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.output = parent / ("ui-edges-" + str(time.time_ns()))
        self.output.mkdir(mode=0o700)
        self.report = {"run_id": self.run_id, "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=5).strip(),
                       "environment": "local-installed-chrome", "evidence_level": "live-browser-read-only-subset",
                       "complete_L17": False, "checks": [], "page_error_count": 0,
                       "unexercised": ["deleted detail", "newly appearing partition", "failed backend query", "other Memory pages"]}
        self.sockets = []
        self.offline = False

    def url(self, partition, path="/memory/memories", **extra):
        return self.base + path + "?" + urllib.parse.urlencode({**partition, **extra})

    def observe_socket(self, route):
        remote = route.connect_to_server()
        self.sockets.append((route, remote))

    def screenshot(self, page, name):
        path = self.output / (name + ".png")
        page.locator("#memory-memories").screenshot(path=str(path), timeout=10000)
        os.chmod(path, 0o600)
        return path.name

    def connected(self, page, timeout=15000):
        page.locator("[data-phx-main].phx-connected").wait_for(timeout=timeout)
        require(page.locator("#memories-error").count() == 0, "memory_query_failed")

    def open(self, page, url):
        response = page.goto(url, wait_until="networkidle", timeout=20000)
        require(response and response.status == 200, "admin_http_status")
        self.connected(page)
        page.locator("#memory-memories").wait_for()

    def preserved(self, page, partition, offset):
        params = query(page.url)
        require(all(params.get(key) == value for key, value in partition.items()), "partition_selection_lost")
        require(params.get("q") == self.search and int(params.get("offset", 0)) == offset, "filter_or_offset_lost")
        require(page.locator('[name="filters[q]"]').input_value() == self.search, "filter_input_lost")

    def ids(self, page):
        links = page.locator("#memory-memories-table tbody a").evaluate_all("nodes => nodes.map(node => node.getAttribute('href'))")
        ids = [urllib.parse.urlsplit(link).path.rsplit("/", 1)[-1] for link in links]
        for value in ids:
            uuid.UUID(value)
        return ids

    def pagination(self, page):
        self.open(page, self.url(self.primary))
        page.locator('[name="filters[q]"]').fill(self.search)
        page.locator('#memories-filters button[type="submit"]').click()
        page.wait_for_url(lambda url: query(str(url)).get("q") == self.search)
        self.connected(page)
        self.preserved(page, self.primary, 0)
        total = int(page.locator("#memories-count").inner_text().split()[0])
        first = self.ids(page)
        self.report["pagination_precondition"] = {"query": self.search, "matching_count": total, "first_page_count": len(first)}
        require(total > 25 and len(first) == 25, "multi_page_fixture_required")
        first_shot = self.screenshot(page, "pagination-first")
        page.locator("#memories-next").click()
        page.wait_for_url(lambda url: query(str(url)).get("offset") == "25")
        self.connected(page)
        self.preserved(page, self.primary, 25)
        second = self.ids(page)
        require(second and not (set(first) & set(second)), "pagination_did_not_advance")
        second_shot = self.screenshot(page, "pagination-next")
        page.locator("#memories-previous").click()
        page.wait_for_url(lambda url: query(str(url)).get("offset") == "0")
        self.connected(page)
        self.preserved(page, self.primary, 0)
        require(self.ids(page) == first, "pagination_previous_did_not_restore")
        return {"matching_count": total, "first_ids": first, "second_ids": second,
                "partition_filter_preserved": True, "screenshots": [first_shot, second_shot]}

    def unknown_detail(self, page):
        target = str(uuid.uuid5(uuid.NAMESPACE_URL, "backplane-ui-unknown:" + self.run_id))
        self.open(page, self.url(self.primary, "/memory/memories/" + target, q=self.search, offset=25))
        page.locator("#memory-detail-unavailable").wait_for()
        require(page.locator("#memory-detail").count() == 0, "unknown_detail_not_readable")
        require("missing, deleted, or unavailable" in page.locator("#memory-detail-unavailable").inner_text(), "unknown_detail_message_missing")
        self.preserved(page, self.primary, 25)
        return {"unknown_id": target, "unavailable_state_visible": True, "visible_inventory_count": len(self.ids(page)),
                "screenshot": self.screenshot(page, "unknown-detail")}

    def empty_partition(self, page):
        self.open(page, self.url(self.isolated))
        count = int(page.locator("#memories-count").inner_text().split()[0])
        if count != 0:
            self.report["unexercised"].append("empty partition (fixture no longer empty)")
            return {"skipped": "fixture_no_longer_empty", "matching_count": count,
                    "requires_host_process": False, "screenshot": self.screenshot(page, "isolated-nonempty")}
        page.locator("#memories-empty").wait_for()
        require(page.locator("#memories-count").inner_text().split()[0] == "0", "isolated_fixture_not_empty")
        require(not self.ids(page) and page.locator("#memories-next").count() == 0, "empty_partition_has_rows")
        require(all(query(page.url).get(key) == value for key, value in self.isolated.items()), "empty_partition_selection_lost")
        return {"selection": self.isolated, "matching_count": 0, "requires_host_process": False,
                "screenshot": self.screenshot(page, "empty-partition")}

    def reconnect(self, context, page):
        progress = {"stage": "opening_page", "network_fault_applied": False, "disconnect_observed": False}
        self.report["reconnect_progress"] = progress
        self.open(page, self.url(self.primary, q=self.search, offset=25))
        page.locator("#memory-memories-table tbody a").first.click()
        page.locator("#memory-detail").wait_for()
        self.connected(page)
        self.preserved(page, self.primary, 25)
        retained_url, retained_ids = page.url, self.ids(page)
        progress["stage"] = "detail_retained"
        require(self.sockets, "live_transport_not_observed")
        navigations = []
        page.on("framenavigated", lambda frame: navigations.append(1) if frame == page.main_frame else None)
        document_requests = []
        page.on("request", lambda request: document_requests.append(1)
                if request.is_navigation_request() and request.frame == page.main_frame else None)
        # LiveView history patches also emit framenavigated. A marker assigned
        # once to this Document must survive; a replacement document loses it.
        document_before = page.evaluate("""marker => {
            document.__memoryLocalReconnectProbe = marker;
            return {marker, timeOrigin: performance.timeOrigin};
        }""", str(uuid.uuid4()))
        started = time.monotonic()
        try:
            context.set_offline(True)
            self.offline = True
            progress.update(stage="browser_offline", network_fault_applied=True)
            require(page.evaluate("navigator.onLine") is False, "browser_not_offline")
            # Chrome may retain existing sockets under network emulation. Close
            # only this browser's routed transport to make the fault deterministic.
            for local, remote in self.sockets[-1:]:
                local.close(code=1001, reason="local browser offline probe")
                remote.close(code=1001, reason="local browser offline probe")
            # Phoenix LiveView marks transport loss with phx-loading and error
            # classes; phx-disconnected is a JS command binding, not a class.
            page.locator("[data-phx-main].phx-loading:not(.phx-connected)").wait_for(timeout=8000)
            progress.update(stage="disconnect_observed", disconnect_observed=True)
            require(page.url == retained_url, "offline_url_changed")
            self.preserved(page, self.primary, 25)
            require(page.locator("#memory-detail").count() == 1, "offline_detail_lost")
            offline_shot = self.screenshot(page, "browser-offline")
        finally:
            context.set_offline(False)
            self.offline = False
            progress["stage"] = "browser_online"
        remaining = 30000 - round((time.monotonic() - started) * 1000)
        require(remaining > 0, "reconnect_budget_exhausted")
        self.connected(page, timeout=remaining)
        progress["stage"] = "reconnected"
        require(page.evaluate("navigator.onLine") is True, "browser_not_online")
        elapsed = round((time.monotonic() - started) * 1000)
        require(elapsed <= 30000, "reconnect_exceeded_30_seconds")
        document_after = page.evaluate("""() => ({
            marker: document.__memoryLocalReconnectProbe ?? null,
            timeOrigin: performance.timeOrigin
        })""")
        document_check = {
            "exact_url_preserved": page.url == retained_url,
            "document_marker_preserved": document_after["marker"] == document_before["marker"],
            "time_origin_preserved": document_after["timeOrigin"] == document_before["timeOrigin"],
            "main_frame_navigation_requests": len(document_requests),
            "main_frame_navigation_events": len(navigations),
        }
        progress["document_check"] = document_check
        require(document_check["exact_url_preserved"], "reconnect_url_changed")
        require(document_check["document_marker_preserved"] and document_check["time_origin_preserved"]
                and not document_requests, "reconnect_document_reloaded")
        self.preserved(page, self.primary, 25)
        require(page.locator("#memory-detail").count() == 1 and self.ids(page) == retained_ids, "reconnect_detail_or_page_lost")
        return {"retained_path": urllib.parse.urlsplit(retained_url).path, "retained_query": query(retained_url),
                "offline_transport": "browser-network-offline-and-owned-websocket-close",
                "disconnect_observed": True, "connected_after_ms": elapsed, "reload": False,
                "document_check": document_check,
                "screenshots": [offline_shot, self.screenshot(page, "browser-reconnected")]}

    def check(self, name, operation):
        started = time.monotonic()
        try:
            detail = operation()
            row = {"check": name, "status": "skipped" if detail.get("skipped") else "passed", "detail": detail}
        except Exception as error:
            row = {"check": name, "status": "failed", "failure": str(error) if isinstance(error, CheckFailed) else type(error).__name__}
        row["elapsed_ms"] = round((time.monotonic() - started) * 1000)
        self.report["checks"].append(row)
        self.save()

    def save(self):
        path = self.output / "report.json"
        temporary = self.output / "report.tmp"
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
            json.dump(self.report, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        return path

    def run(self):
        from playwright.sync_api import sync_playwright
        try:
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(channel="chrome", headless=True)
                try:
                    context = browser.new_context(viewport={"width": 1440, "height": 1000})
                    context.set_default_timeout(10000)
                    context.route_web_socket("**/live/websocket**", self.observe_socket)
                    page = context.new_page()
                    page.on("pageerror", lambda _: self.report.update(page_error_count=self.report["page_error_count"] + 1))
                    for name, operation in (("pagination", lambda: self.pagination(page)),
                                            ("unknown_detail", lambda: self.unknown_detail(page)),
                                            ("empty_partition", lambda: self.empty_partition(page)),
                                            ("browser_disconnect_reconnect", lambda: self.reconnect(context, page))):
                        self.check(name, operation)
                    context.set_offline(False)
                    context.close()
                finally:
                    browser.close()
        except Exception as error:
            self.report["browser_failure"] = type(error).__name__
        passed = len(self.report["checks"]) == 4 and all(row["status"] in ("passed", "skipped") for row in self.report["checks"])
        passed = passed and self.report["page_error_count"] == 0 and "browser_failure" not in self.report
        skipped = any(row["status"] == "skipped" for row in self.report["checks"])
        self.report["status"] = ("passed-subset-with-skips" if skipped else "passed-subset") if passed else "failed"
        print(self.save())
        return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--admin-url", default="http://127.0.0.1:4221")
    parser.add_argument("--search", help="nonempty text filter matching more than 25 fixture memories; defaults to e")
    args = parser.parse_args()
    return Edges(args.fixture, args.admin_url, args.search).run()


if __name__ == "__main__":
    raise SystemExit(main())
