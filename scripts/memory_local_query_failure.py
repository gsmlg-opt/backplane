#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Observe a fixture-only query error and corrective-filter recovery in local Chrome.

Only this browser's existing pagination anchor is temporarily retargeted. No DB,
services, settings, or production code are changed. This is an L17 subset, not
automatic recovery from a transient backend outage with unchanged filters.
"""

import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import time
import urllib.parse
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CheckFailed(RuntimeError):
    """Fixed nonsecret diagnostic code; never retain raw browser/server errors."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def local_url(value):
    try:
        parsed = urllib.parse.urlsplit(value)
        valid = (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                 and parsed.username is None and parsed.password is None and parsed.path in ("", "/")
                 and not parsed.query and not parsed.fragment and 0 < (parsed.port or 80) <= 65535
                 and parsed.port != 0)
    except ValueError:
        valid = False
    require(valid, "loopback_http_base_required")
    return value.rstrip("/")


def fixture_selection(fixture):
    run_id = fixture.get("run_id")
    require(isinstance(run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id_invalid")
    hosts = fixture.get("hosts", [])
    require(isinstance(hosts, list) and len(hosts) >= 2, "two_fixture_partitions_required")
    selections = []
    for host, suffix in zip(hosts[:2], ("primary", "isolated")):
        partition = host.get("partition", {})
        try:
            for key in ("memory_space_id", "host_id"):
                require(str(uuid.UUID(partition[key])) == partition[key], "fixture_uuid_invalid")
        except (KeyError, ValueError, TypeError, AttributeError):
            raise CheckFailed("fixture_uuid_invalid") from None
        require(partition.get("client_id") == "host:" + partition["host_id"]
                and partition.get("scope") == "memory_local_" + run_id + "_" + suffix
                and partition.get("namespace") == "private", "fixture_partition_not_owned")
        selections.append({"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                           "client": partition["client_id"], "scope": partition["scope"], "namespace": "private"})
    require(selections[0]["memory_space_id"] != selections[1]["memory_space_id"], "distinct_fixture_spaces_required")
    return selections[0]


def query(url):
    pairs = urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query, keep_blank_values=True)
    require(len(pairs) == len(dict(pairs)), "duplicate_query_parameters")
    return dict(pairs)


def fault_url(original, base, selection, run_id):
    local_url(base)
    parsed, origin = urllib.parse.urlsplit(original), urllib.parse.urlsplit(base)
    params = query(original)
    require(parsed.scheme == origin.scheme and parsed.netloc == origin.netloc and not parsed.fragment,
            "detail_origin_not_owned")
    require(re.fullmatch(r"/memory/memories/[0-9a-f-]{36}", parsed.path), "fixture_detail_path_required")
    try:
        uuid.UUID(parsed.path.rsplit("/", 1)[-1])
    except ValueError:
        raise CheckFailed("fixture_detail_id_invalid") from None
    require(all(params.get(key) == value for key, value in selection.items())
            and params.get("q") == "e" and params.get("offset") == "25", "fixture_selection_not_retained")
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id_invalid")
    # A short synthetic marker plus NUL is bound as PostgreSQL text. The browser
    # alert alone does not establish a SQLSTATE; correlate server evidence separately.
    params["q"] = "memory-local-" + run_id[:16] + "\0query"
    return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(params)))


def controlled_fault(ui, original, fault, report):
    report["restoration"] = {"attempted": False, "verified": False}
    try:
        ui.patch(fault)
        report["fault"] = ui.observe_error(fault)
    except Exception as error:
        raise CheckFailed(str(error) if isinstance(error, CheckFailed) else type(error).__name__) from None
    finally:
        report["restoration"]["attempted"] = True
        try:
            ui.patch(original)
            report["recovery"] = ui.observe_recovery(original)
            report["restoration"]["verified"] = True
        except (Exception, KeyboardInterrupt):
            raise CheckFailed("RESTORATION_NOT_PROVEN") from None


def classify(report):
    passed = (report.get("fault", {}).get("observed") is True
              and report.get("recovery", {}).get("observed") is True
              and report.get("restoration", {}).get("verified") is True
              and report.get("page_error_count") == 0 and report.get("context_closed") is True
              and "failure" not in report)
    return "passed-corrective-filter-subset" if passed else "failed"


class QueryUI:
    def __init__(self, page, base, selection, output, report):
        self.page, self.base, self.selection = page, base, selection
        self.output, self.report = output, report
        self.document_requests = []

    def ids(self):
        links = self.page.locator("#memory-memories-table tbody a").evaluate_all(
            "nodes => nodes.map(node => node.getAttribute('href'))")
        ids = [urllib.parse.urlsplit(link).path.rsplit("/", 1)[-1] for link in links]
        require(all(str(uuid.UUID(value)) == value for value in ids), "inventory_ids_invalid")
        return ids

    def screenshot(self, name):
        path = self.output / (name + ".png")
        self.page.locator("#memory-memories").screenshot(path=str(path), timeout=5000)
        os.chmod(path, 0o600)
        return path.name

    def prepare(self):
        url = self.base + "/memory/memories?" + urllib.parse.urlencode({**self.selection, "q": "e", "offset": 25})
        response = self.page.goto(url, wait_until="networkidle", timeout=20000)
        require(response and response.status == 200, "admin_http_status")
        self.page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
        self.page.locator("#memory-memories-table tbody a").first.wait_for(timeout=15000)
        require(self.page.locator("#memories-error").count() == 0, "baseline_query_failed")
        require(int(self.page.locator("#memories-count").inner_text().split()[0]) > 25, "multi_page_fixture_required")
        detail_link = self.page.locator("#memory-memories-table tbody a").first
        detail_url = urllib.parse.urljoin(self.base, detail_link.get_attribute("href"))
        fault_url(detail_url, self.base, self.selection, self.report["run_id"])
        detail_link.click()
        self.page.locator("#memory-detail").wait_for(timeout=15000)
        self.original, self.retained_ids = self.page.url, self.ids()
        require(bool(self.retained_ids), "populated_fixture_page_required")
        self.page.locator("#memories-previous[data-phx-link='patch']").wait_for()
        self.document = self.page.evaluate("""marker => {
            document.__memoryLocalQueryFailureProbe = marker;
            return {marker, timeOrigin: performance.timeOrigin};
        }""", str(uuid.uuid4()))
        self.page.on("request", lambda request: self.document_requests.append(1)
                     if request.is_navigation_request() and request.frame == self.page.main_frame else None)
        self.report["baseline"] = {"url": self.original, "ids": self.retained_ids,
                                   "screenshot": self.screenshot("query-healthy")}
        return self.original

    def remaining(self):
        remaining = round((self.deadline - time.monotonic()) * 1000)
        require(remaining > 0, "query_phase_exceeded_15_seconds")
        return remaining

    def patch(self, url):
        self.started = time.monotonic()
        self.deadline = self.started + 15
        # Modify only the href of an existing pagination patch anchor in this
        # driver's private browser context; click through normal LiveView handling.
        anchor = self.page.locator("#memories-previous[data-phx-link='patch']")
        anchor.evaluate("(node, url) => node.setAttribute('href', url)", url, timeout=self.remaining())
        anchor.click(timeout=self.remaining())

    def retained(self, url):
        require(self.page.url == url, "exact_url_not_retained")
        self.page.locator("[data-phx-main].phx-connected").wait_for(timeout=self.remaining())
        document = self.page.evaluate("""() => ({marker: document.__memoryLocalQueryFailureProbe ?? null,
                                                timeOrigin: performance.timeOrigin})""")
        require(document == self.document and not self.document_requests, "document_reloaded")
        require(self.report["page_error_count"] == 0, "browser_page_errors_observed")
        params = query(url)
        require(all(params.get(key) == value for key, value in self.selection.items())
                and params.get("offset") == "25"
                and urllib.parse.urlsplit(url).path == urllib.parse.urlsplit(self.original).path,
                "partition_offset_or_detail_route_lost")
        return {"document_marker_preserved": True, "time_origin_preserved": True,
                "main_frame_navigation_requests": len(self.document_requests), "exact_url_retained": True}

    def observe_error(self, url):
        self.page.wait_for_url(url, timeout=self.remaining())
        self.page.locator("#memories-error").wait_for(timeout=self.remaining())
        screenshot = self.screenshot("query-error")
        self.report["error_observation"] = {"alert_visible": True, "screenshot": screenshot}
        require("The bounded partition query failed." in self.page.locator("#memories-error").inner_text(),
                "query_error_message_missing")
        require(all(self.page.locator(selector).count() == 0 for selector in
                    ("#memories-empty", "#memories-count", "#memory-detail", "#memory-detail-unavailable")),
                "query_failure_rendered_misleading_success")
        require(not self.ids(), "query_failure_retained_success_rows")
        document = self.retained(url)
        elapsed = round((time.monotonic() - self.started) * 1000)
        self.remaining()
        return {"observed": True, "elapsed_ms": elapsed, "document": document,
                "sqlstate": None, "sqlstate_evidence": "not exposed by browser; correlate sanitized server evidence separately",
                "screenshot": screenshot}

    def observe_recovery(self, url):
        self.page.wait_for_url(url, timeout=self.remaining())
        self.page.locator("#memory-detail").wait_for(timeout=self.remaining())
        self.page.locator("#memories-count").wait_for(timeout=self.remaining())
        require(self.page.locator("#memories-error").count() == 0
                and self.page.locator("#memories-empty").count() == 0, "query_recovery_not_healthy")
        require(self.page.locator('[name="filters[q]"]').input_value() == "e"
                and self.ids() == self.retained_ids, "original_filter_or_rows_not_restored")
        document = self.retained(url)
        elapsed = round((time.monotonic() - self.started) * 1000)
        self.remaining()
        return {"observed": True, "elapsed_ms": elapsed, "document": document,
                "screenshot": self.screenshot("query-corrected")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--admin-url", default="http://127.0.0.1:4221")
    args = parser.parse_args()
    base = local_url(args.admin_url)
    fixture = json.loads(args.fixture.read_text())
    selection = fixture_selection(fixture)
    output = ROOT / ".devenv/memory-local-evidence" / fixture["run_id"] / ("query-failure-" + str(time.time_ns()))
    output.mkdir(parents=True, mode=0o700)
    report = {"run_id": fixture["run_id"], "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=5).strip(),
              "evidence_level": "live-browser-request-scoped-query-error-and-corrective-filter-recovery",
              "complete_L17": False, "unchanged_filter_automatic_recovery": "not exercised",
              "fault_mechanism": "NUL-bearing bound search parameter via owned existing pagination patch anchor",
              "selection": selection, "page_error_count": 0, "context_closed": False,
              "restoration": {"attempted": False, "verified": False}, "per_phase_budget_ms": 15000}
    def interrupt(_signum, _frame):
        raise InterruptedError("interrupted")

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            try:
                context = browser.new_context(viewport={"width": 1440, "height": 1000})
                try:
                    context.set_default_timeout(10000)
                    page = context.new_page()
                    page.on("pageerror", lambda _: report.update(page_error_count=report["page_error_count"] + 1))
                    ui = QueryUI(page, base, selection, output, report)
                    original = ui.prepare()
                    fault = fault_url(original, base, selection, fixture["run_id"])
                    controlled_fault(ui, original, fault, report)
                finally:
                    context.close()
                    report["context_closed"] = True
            finally:
                browser.close()
    except (Exception, KeyboardInterrupt) as error:
        report["failure"] = str(error) if isinstance(error, CheckFailed) else type(error).__name__
    finally:
        signal.signal(signal.SIGTERM, previous)
        report["status"] = classify(report)
        path = output / "report.json"
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
            json.dump(report, stream, indent=2)
        print(path)
    return 0 if report["status"] == "passed-corrective-filter-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
