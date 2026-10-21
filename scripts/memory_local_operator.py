#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Observe real session consolidation and evidence navigation in local Chrome."""

import argparse
import json
import os
import time
import urllib.parse
from pathlib import Path

from memory_local_acceptance import Acceptance


def captured_session(value):
    if not value.strip() or len(value.encode("utf-8")) > 512:
        raise argparse.ArgumentTypeError("session must be nonempty and at most 512 UTF-8 bytes")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--session", type=captured_session,
                        help="captured session ID (defaults to the fixture acceptance session)")
    args = parser.parse_args()
    run = Acceptance(args.fixture, "http://127.0.0.1:4222", 90)
    session = args.session if args.session is not None else run.session
    partition = run.fixture["hosts"][0]["partition"]
    selection = {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                 "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}
    query = urllib.parse.urlencode(selection)
    output = run.output / ("operator-" + str(time.time_ns()))
    output.mkdir(mode=0o700)
    report = {"run_id": run.run_id, "session": session, "complete_L01_L18": False,
              "evidence_level": "live-browser-operator-subset", "errors": [], "navigation": []}
    from playwright.sync_api import sync_playwright
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            page = browser.new_page(viewport={"width": 1440, "height": 1000})
            page.on("pageerror", lambda error: report["errors"].append(str(error)))
            url = "http://127.0.0.1:4221/memory/sessions/" + urllib.parse.quote(session, safe="") + "?" + query
            page.goto(url, wait_until="domcontentloaded", timeout=30000)
            page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
            page.locator("#session-consolidate").wait_for()
            progress = page.locator("#session-consolidation-progress")
            report["before"] = json.loads(progress.inner_text())
            page.locator("#session-consolidate").click()
            page.wait_for_timeout(750)
            report["first_action"] = json.loads(progress.inner_text())
            page.locator("#session-consolidate").click()
            page.wait_for_timeout(750)
            report["second_action"] = json.loads(progress.inner_text())
            revisions = {report[key]["input_revision"] for key in ("before", "first_action", "second_action")}
            if len(revisions) != 1:
                raise RuntimeError("source revision changed during unchanged-session retry")
            if report["first_action"]["artifact_ids"] != report["second_action"]["artifact_ids"]:
                raise RuntimeError("repeated unchanged-session action changed artifact identities")
            report["unchanged_revision_artifacts_stable"] = True
            page.screenshot(path=str(output / "consolidation.png"))
            # Follow links rendered by the selected session, retaining its partition.
            links = page.locator("#memory-session-detail a[href]").evaluate_all(
                "nodes => nodes.map(n => ({text:n.textContent.trim(),href:n.getAttribute('href')}))")
            for link in links:
                href = link["href"]
                if not href.startswith("/memory/"):
                    continue
                target = "http://127.0.0.1:4221" + href
                response = page.goto(target, wait_until="domcontentloaded", timeout=30000)
                page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
                parsed = urllib.parse.parse_qs(urllib.parse.urlparse(page.url).query)
                if response.status != 200 or any(parsed.get(k) != [v] for k, v in selection.items()):
                    raise RuntimeError("session evidence link lost exact selection or failed")
                report["navigation"].append({"label": link["text"], "url": page.url, "status": response.status})
                page.screenshot(path=str(output / ("navigation-" + str(len(report["navigation"])) + ".png")))
            missing = "http://127.0.0.1:4221/memory/sessions/memory-local-missing?" + query
            page.goto(missing, wait_until="domcontentloaded")
            page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
            page.locator("#session-detail-error").wait_for()
            report["unknown_session"] = "explicit-unavailable"
            page.screenshot(path=str(output / "unknown-session.png"))
            browser.close()
        if report["errors"]:
            raise RuntimeError("browser page errors observed")
        report["status"] = "observed-subset"
        report["limit"] = "Actions and navigation observed; canonical snapshots must verify unchanged-revision idempotency and artifacts."
        code = 0
    except Exception as error:
        report.update(status="failed", error=str(error))
        code = 1
    path = output / "report.json"
    path.write_text(json.dumps(report, indent=2))
    for file in output.iterdir():
        os.chmod(file, 0o600)
    print(path)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
