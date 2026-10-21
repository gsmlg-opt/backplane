#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Run bounded browser observations with installed Chrome: uv run this-file --fixture PATH."""

import argparse
import json
import os
import re
import time
import urllib.parse
import uuid
from pathlib import Path

from memory_local_acceptance import Acceptance


def load_recall_report(path, run_id):
    """Accept only four successful trace cases for this fixture; discard report URLs."""
    def valid_uuid(value):
        try:
            return isinstance(value, str) and str(uuid.UUID(value)) == value
        except ValueError:
            return False

    with path.open("rb") as stream:
        raw = stream.read(4_000_001)
    if len(raw) > 4_000_000:
        raise ValueError("recall report exceeds bounded evidence size")
    report = json.loads(raw)
    if not isinstance(report, dict) or report.get("run_id") != run_id or report.get("phase") != "recall" or report.get("status") != "passed-subset" or report.get("complete_L01_L18") is not False:
        raise ValueError("recall report must be a passed API subset for this fixture run")
    detail = report.get("detail")
    if not isinstance(detail, dict):
        raise ValueError("recall report detail is missing")
    expected = detail.get("expected_ids")
    cases = detail.get("cases")
    if not isinstance(expected, list) or not 1 <= len(expected) <= 50 or not all(valid_uuid(value) for value in expected):
        raise ValueError("recall report must identify discovered preference UUIDs")
    if not isinstance(cases, list) or len(cases) != 4:
        raise ValueError("recall report must contain exactly four cases")
    identities, traces, validated = set(), set(), []
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("invalid recall case")
        identity = (case.get("interface"), case.get("case"))
        trace, query = case.get("trace"), case.get("query")
        ids, used, budget = case.get("result_ids"), case.get("used_tokens"), case.get("token_budget")
        if identity not in {(interface, name) for interface in ("direct", "mcp") for name in ("exact", "paraphrase")} or identity in identities or not valid_uuid(trace) or trace in traces:
            raise ValueError("recall report contains duplicate or invalid trace cases")
        if not isinstance(query, str) or not query.strip() or len(query) > 4096:
            raise ValueError("recall report query is invalid")
        if not isinstance(ids, list) or len(ids) > 50 or not all(valid_uuid(value) for value in ids) or not set(expected).intersection(ids):
            raise ValueError("recall report has no discovered preference hit")
        if type(used) is not int or not 0 < used <= 2048 or type(budget) is not int or budget != 2048:
            raise ValueError("recall report token budget is invalid")
        row = {key: case[key] for key in ("interface", "case", "query", "trace", "result_ids", "used_tokens", "token_budget")}
        row["expected_ids"] = expected
        model = case.get("query_embedding_model")
        if model is not None:
            if not isinstance(model, str) or not model.strip() or len(model) > 512:
                raise ValueError("recall report embedding model is invalid")
            row["query_embedding_model"] = model
        identities.add(identity)
        traces.add(trace)
        validated.append(row)
    return validated


def observe_recall(page, cases, selection, admin_url, output, report):
    """Compare actual inspector DOM with the four API traces, without issuing recalls."""
    report["recall_trace_observations"] = []
    for case in cases:
        name = "recall-" + case["interface"] + "-" + case["case"]
        url = admin_url.rstrip("/") + "/memory/recall/" + case["trace"] + "?" + urllib.parse.urlencode(selection)
        response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
        if response is None or response.status != 200:
            raise RuntimeError(name + " did not return HTTP 200")
        page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
        page.locator("#recall-run-detail").wait_for(timeout=15000)
        screenshot = output / (name + ".png")
        page.screenshot(path=str(screenshot), full_page=True)
        (output / (name + ".txt")).write_text(page.locator("body").inner_text())
        values = dict(page.locator("#recall-run-detail dl dt").evaluate_all(
            "nodes => nodes.map(node => [node.textContent.trim(), node.nextElementSibling.textContent.trim()])"))
        expected_values = {"Run ID": case["trace"], "Normalized query": case["query"], "Status": "complete",
                           "Host": selection["host"], "Client": selection["client"],
                           "Scope": selection["scope"], "Namespace": selection["namespace"]}
        if "query_embedding_model" in case:
            expected_values["Embedding model"] = case["query_embedding_model"]
        progress = page.get_by_role("progressbar", name="Recall token budget used", exact=True)
        budget = {"used_tokens": progress.get_attribute("value"), "token_budget": progress.get_attribute("max")}
        candidates = page.locator("#recall-candidates-table tbody tr").evaluate_all("""nodes => nodes.map(node => {
            const cells = node.querySelectorAll('td');
            return {id: cells[0].querySelector('span').textContent.trim(),
                    decision: cells[1].textContent.trim(), budget: cells[4].textContent.trim(),
                    provenance: Array.from(cells[5].querySelectorAll('[aria-label="Typed provenance"] li'), li => li.textContent.trim())};
        })""")
        selected = [row for row in candidates if row["decision"].startswith("Selected")]
        targets = [row for row in selected if row["id"] in case["expected_ids"]]
        excluded = [row for row in candidates if row["decision"].startswith("Rejected") and "Excluded" in row["decision"] and "(excluded)" in row["budget"]]
        provenance = bool(targets) and all(row["provenance"] and all(re.fullmatch(r"[a-z_]+: .+", ref) for ref in row["provenance"]) for row in targets)
        observation = {"interface": case["interface"], "case": case["case"], "trace": case["trace"],
                       "url": url, "screenshot": str(screenshot), "query_and_partition_match": all(values.get(key) == value for key, value in expected_values.items()),
                       "model_compared": "query_embedding_model" in case, "embedding_model_visible": values.get("Embedding model"),
                       "budget_matches": budget == {"used_tokens": str(case["used_tokens"]), "token_budget": str(case["token_budget"])},
                       "budget": budget, "selected_ids": [row["id"] for row in selected],
                       "expected_selected_ids": [row["id"] for row in targets], "typed_provenance_visible": provenance,
                       "excluded_candidates_visible": len(excluded)}
        report["recall_trace_observations"].append(observation)
        if not observation["query_and_partition_match"] or not observation["budget_matches"] or not targets or not provenance or not excluded:
            raise RuntimeError(name + " inspector does not agree with the API trace; inspect screenshot and report")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--admin-url", default="http://127.0.0.1:4221")
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--observe-write", action="store_true", help="create a synthetic command after opening Memories")
    parser.add_argument("--recall-report", type=Path, help="also compare four trace pages with a passed api-recall report")
    args = parser.parse_args()
    parsed = urllib.parse.urlparse(args.admin_url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1") or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("Admin must use local HTTP")

    from playwright.sync_api import sync_playwright

    run = Acceptance(args.fixture, args.host_url, 90)
    recall_cases = load_recall_report(args.recall_report, run.run_id) if args.recall_report else None
    stamp = str(time.time_ns())
    output = run.output / ("browser-" + stamp)
    output.mkdir(mode=0o700)
    partition = run.fixture["hosts"][0]["partition"]
    selection = {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                 "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}
    report = {"run_id": run.run_id, "evidence_level": "live-browser-subset", "complete_L01_L18": False,
              "selection": selection, "pages": [], "errors": [], "write_observation": None}
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            context = browser.new_context(viewport={"width": 1440, "height": 1000})
            page = context.new_page()
            page.on("pageerror", lambda error: report["errors"].append(str(error)))
            for name in ("overview", "events", "sessions", "memories", "pipeline", "graph", "lessons", "crystals", "profile", "recall", "config", "audit"):
                path = "/memory" if name == "overview" else "/memory/" + name
                url = args.admin_url.rstrip("/") + path + "?" + urllib.parse.urlencode(selection)
                response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
                if response.status != 200:
                    raise RuntimeError(f"{name} HTTP {response.status}")
                page.locator("[data-phx-main].phx-connected").wait_for(timeout=15000)
                body = page.locator("body").inner_text()
                if "Phoenix.Router.NoRouteError" in body or "UndefinedFunctionError" in body:
                    raise RuntimeError(f"{name} rendered an exception")
                screenshot = output / (name + ".png")
                page.screenshot(path=str(screenshot), full_page=False)
                (output / (name + ".txt")).write_text(body)
                report["pages"].append({"page": name, "url": url, "status": response.status,
                                        "live_connected": True, "screenshot": str(screenshot)})

            if args.observe_write:
                marker = run.marker + "-BROWSER-" + stamp
                query = {**selection, "q": marker}
                url = args.admin_url.rstrip("/") + "/memory/memories?" + urllib.parse.urlencode(query)
                page.goto(url, wait_until="domcontentloaded")
                page.locator("[data-phx-main].phx-connected").wait_for()
                page.locator("#memories-empty").wait_for()
                started = time.monotonic()
                accepted = run.direct("remember", {"content": marker + ": Synthetic browser refresh observed after durable host acceptance.",
                                                     "type": "semantic", "scope": run.scope,
                                                     "idempotency_key": marker})
                # No navigation, forced notification, or page reload after the mutation.
                page.get_by_role("link", name=marker + ": Synthetic browser refresh observed after durable host acceptance.", exact=True).wait_for(timeout=5000)
                elapsed = round((time.monotonic() - started) * 1000)
                if page.url != url or elapsed > 5000:
                    raise RuntimeError("browser write visibility exceeded five-second acceptance budget or lost selection")
                page.screenshot(path=str(output / "live-write.png"), full_page=False)
                report["write_observation"] = {"marker": marker, "acceptance": accepted, "visible_after_ms": elapsed,
                                                "clock_origin": "before host durable write request", "reload": False}
                run.save("browser-write", "passed-subset", detail=report["write_observation"])
            if recall_cases:
                observe_recall(page, recall_cases, selection, args.admin_url, output, report)
            browser.close()
        if report["errors"]:
            raise RuntimeError("browser page errors observed")
        report["status"] = "passed-subset"
        return_code = 0
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        return_code = 1
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2))
    for path in output.iterdir():
        os.chmod(path, 0o600)
    print(str(report_path))
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
