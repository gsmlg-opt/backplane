#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.56.0"]
# ///
"""Exercise a dedicated local fixture's embedding failure and real recovery via Admin UI.

Run only after confirming no embedding jobs can run during the short fault window.
This covers an embedding/recall subset of L15, not invalid structured LLM output.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import re
import signal
import subprocess
import time
import urllib.parse
import uuid
from pathlib import Path

from memory_local_acceptance import Acceptance, ROOT


QUERIES = {"exact": "bounded OTP workers",
           "paraphrase": "Which worker design does this project favor over limitless background execution?"}


class CheckError(RuntimeError):
    """A fixed, nonsecret diagnostic code safe to retain in evidence."""


def require(condition, code):
    if not condition:
        raise CheckError(code)


def is_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def local_url(value):
    try:
        parsed = urllib.parse.urlsplit(value)
        valid = (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                 and not parsed.username and not parsed.password and parsed.path in ("", "/")
                 and not parsed.query and not parsed.fragment and 1 <= (parsed.port or 80) <= 65535
                 and parsed.port != 0)
    except ValueError:
        valid = False
    require(valid, "loopback_http_base_required")
    return value.rstrip("/")


def fixture_identity(fixture):
    run_id = fixture.get("run_id")
    require(isinstance(run_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id), "fixture_run_id_invalid")
    provider = "memory-local-" + run_id
    model = provider + "/openai/text-embedding-3-large"
    require(fixture.get("models", [])[1:2] == [model]
            and fixture.get("settings", {}).get("memory.embed_model") == model, "fixture_embedding_model_not_owned")
    hosts = fixture.get("hosts")
    require(isinstance(hosts, list) and hosts and isinstance(hosts[0], dict), "fixture_host_missing")
    partition = hosts[0].get("partition", {})
    require(is_uuid(partition.get("memory_space_id")) and is_uuid(partition.get("host_id"))
            and partition.get("client_id") == "host:" + partition["host_id"]
            and partition.get("scope") == "memory_local_" + run_id + "_primary"
            and partition.get("namespace") == "private", "fixture_partition_not_owned")
    return {"run_id": run_id, "provider": provider, "model": model,
            "raw_model": "openai/text-embedding-3-large", "credential": provider + "-upstream",
            "selection": {"memory_space_id": partition["memory_space_id"], "host": partition["host_id"],
                          "client": partition["client_id"], "scope": partition["scope"], "namespace": partition["namespace"]}}


def failure_url(original, run_id):
    parsed = urllib.parse.urlsplit(original)
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", run_id)
            and parsed.scheme == "https" and parsed.hostname == "openrouter.ai" and parsed.port in (None, 443)
            and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment
            and parsed.path.rstrip("/") == "/api/v1", "fixture_provider_origin_not_owned")
    return original.rstrip("/") + "/__memory_local_" + run_id + "_failure"


def validate_form(form, identity):
    require(form.get("name") == identity["provider"] and form.get("credential") == identity["credential"]
            and form.get("model") == identity["raw_model"] and form.get("enabled") is True
            and form.get("model_enabled") is True, "provider_form_not_owned_or_enabled")
    failure_url(form.get("base_url", ""), identity["run_id"])
    try:
        require(isinstance(json.loads(form["default_headers"]), dict)
                and json.loads(form["metadata"]).get("dimensions") == 2560, "provider_form_metadata_invalid")
    except (KeyError, ValueError, AttributeError):
        raise CheckError("provider_form_metadata_invalid") from None


def form_summary(form):
    digest = hashlib.sha256(json.dumps(form, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"sha256": digest, "provider": form["name"], "model": form["model"],
            "provider_enabled": form["enabled"], "model_enabled": form["model_enabled"], "base_url": form["base_url"]}


def validate_recall(result, degraded, expected, elapsed_ms):
    require(isinstance(result, dict) and result.get("mode") == "online", "recall_online_required")
    require(is_uuid(result.get("recall_run_id")), "recall_v2_trace_required")
    rows = result.get("results", [])
    require(isinstance(rows, list) and len(rows) <= 50
            and all(isinstance(row, dict) and is_uuid(row.get("id")) for row in rows), "recall_result_id_invalid")
    ids = sorted({row["id"] for row in rows})
    require(bool(set(expected).intersection(ids)), "recall_expected_knowledge_missing")
    used, budget = result.get("used_tokens"), result.get("token_budget")
    require(type(used) is int and 0 < used <= 2048 and type(budget) is int and budget == 2048, "recall_token_budget")
    require(math.isfinite(elapsed_ms) and 0 <= elapsed_ms < 15000, "recall_latency_budget")
    channels = result.get("channels")
    require(isinstance(channels, dict), "recall_channels_missing")
    vector, fts = channels.get("vector", {}), channels.get("fts", {})
    require(isinstance(vector, dict) and isinstance(fts, dict), "recall_channels_missing")
    require(vector.get("status") == ("error" if degraded else "ok")
            and type(vector.get("count")) is int
            and (vector["count"] == 0 if degraded else vector["count"] > 0), "recall_vector_state_wrong")
    if degraded:
        require(fts.get("status") == "ok" and type(fts.get("count")) is int and fts["count"] > 0,
                "recall_lexical_unavailable")
    return {"mode": "online", "trace": result["recall_run_id"], "result_ids": ids, "used_tokens": used,
            "token_budget": budget, "elapsed_ms": elapsed_ms,
            "vector": {key: vector.get(key) for key in ("status", "count", "duration_us")},
            "fts": {key: fts.get(key) for key in ("status", "count", "duration_us")}}


def controlled_fault(ui, original, fault, during, report, checkpoint=lambda: None):
    """Restoration starts even if saving the fault may have committed before raising."""
    report["restoration"] = {"attempted": False, "verified": False}
    try:
        report["fault_attempted"] = True
        checkpoint()
        ui.set_base_url(fault)
        require(ui.read_form() == {**original, "base_url": fault}, "fault_changed_other_form_fields")
        report["fault_applied"] = True
        checkpoint()
        return during()
    except CheckError:
        raise
    except (Exception, KeyboardInterrupt):
        raise CheckError("fault_operation_failed") from None
    finally:
        report["restoration"]["attempted"] = True
        try:
            ui.set_base_url(original["base_url"])
            restored = ui.read_form()
            require(restored == original, "restored_form_differs")
            report["restoration"].update(verified=True, configuration=form_summary(restored))
        except (Exception, KeyboardInterrupt):
            report["restoration"]["error"] = "RESTORATION_NOT_PROVEN"
            raise CheckError("RESTORATION_NOT_PROVEN: restore the dedicated provider before further work") from None
        finally:
            checkpoint()


class ProviderUI:
    def __init__(self, page, admin_url, identity):
        self.page, self.admin_url, self.identity = page, admin_url, identity

    def read_form(self):
        response = self.page.goto(self.admin_url + "/llama/embedding", wait_until="domcontentloaded", timeout=15000)
        require(response is not None and response.status == 200, "provider_page_unavailable")
        self.page.locator("[data-phx-main].phx-connected").wait_for(timeout=10000)
        button = self.page.get_by_role("button", name="Edit embedding provider " + self.identity["provider"], exact=True)
        require(button.count() == 1, "dedicated_provider_row_not_unique")
        button.click()
        self.page.locator("#embedding-provider-form").wait_for(timeout=10000)
        return self.page.locator("#embedding-provider-form").evaluate("""form => {
            const values = {};
            for (const node of form.querySelectorAll('[name^="provider["]')) {
                const key = node.name.slice(9, -1);
                values[key] = node.type === 'checkbox' ? node.checked : node.value;
            }
            return values;
        }""")

    def set_base_url(self, value):
        self.read_form()
        self.page.locator("#embedding-provider-base-url").fill(value)
        self.page.get_by_role("button", name="Save Provider", exact=True).click()
        self.page.locator("#embedding-provider-modal").wait_for(state="hidden", timeout=10000)

    def screenshot(self, path):
        self.page.locator("#embedding-provider-modal > div").screenshot(path=str(path), mask=[
            self.page.locator("#embedding-provider-credential"),
            self.page.locator("#embedding-provider-default-headers"), self.page.locator("#embedding-provider-metadata")])


def observe_trace(page, case, identity, admin_url, output):
    url = admin_url + "/memory/recall/" + case["trace"] + "?" + urllib.parse.urlencode(identity["selection"])
    response = page.goto(url, wait_until="domcontentloaded", timeout=15000)
    require(response is not None and response.status == 200, "trace_page_unavailable")
    page.locator("[data-phx-main].phx-connected").wait_for(timeout=10000)
    page.locator("#recall-run-detail").wait_for(timeout=10000)
    screenshot = output / (case["phase"] + "-" + case["interface"] + "-" + case["case"] + ".png")
    page.locator("#recall-run-detail").screenshot(path=str(screenshot))
    values = dict(page.locator("#recall-run-detail dl dt").evaluate_all(
        "nodes => nodes.map(node => [node.textContent.trim(), node.nextElementSibling.textContent.trim()])"))
    expected_values = {"Run ID": case["trace"], "Normalized query": case["query"], "Status": "complete",
                       "Embedding model": identity["model"], "Host": identity["selection"]["host"],
                       "Client": identity["selection"]["client"], "Scope": identity["selection"]["scope"],
                       "Namespace": identity["selection"]["namespace"]}
    require(all(values.get(key) == value for key, value in expected_values.items()), "trace_identity_query_model_mismatch")
    progress = page.get_by_role("progressbar", name="Recall token budget used", exact=True)
    require(progress.get_attribute("value") == str(case["used_tokens"])
            and progress.get_attribute("max") == "2048", "trace_token_budget_mismatch")
    evidence = json.loads(page.locator("#recall-plan-heading").locator("..").locator("pre").inner_text())
    availability, errors = evidence.get("channel_availability", {}), evidence.get("channel_errors", {})
    degraded = case["phase"] == "degraded"
    require(availability.get("vector") is (not degraded)
            and (errors.get("vector") == "provider_error" if degraded else "vector" not in errors), "trace_vector_state_mismatch")
    if degraded:
        require(availability.get("fts") is True, "trace_lexical_unavailable")
    candidates = page.locator("#recall-candidates-table tbody tr").evaluate_all("""nodes => nodes.map(node => {
        const cells = node.querySelectorAll('td');
        return {id: cells[0].querySelector('span').textContent.trim(), decision: cells[1].textContent.trim(),
                provenance: cells[5].querySelectorAll('[aria-label="Typed provenance"] li').length};
    })""")
    targets = [row["id"] for row in candidates if row["decision"].startswith("Selected")
               and row["id"] in case["expected_ids"] and row["provenance"] > 0]
    require(targets, "trace_selected_preference_provenance_missing")
    return {"phase": case["phase"], "interface": case["interface"], "case": case["case"], "trace": case["trace"],
            "url": url, "screenshot": str(screenshot), "query_partition_model_match": True, "budget_matches": True,
            "vector_available": not degraded, "vector_error": "provider_error" if degraded else None,
            "selected_expected_ids": targets, "typed_provenance_visible": True}


def write_report(path, report):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        os.chmod(temporary, 0o600)
        json.dump(report, stream, indent=2, allow_nan=False)
    temporary.replace(path)


def scenario(run, page, ui, identity, output, report, checkpoint, deadline):
    def remaining():
        require(time.monotonic() < deadline, "scenario_timeout")

    def cases(phase, names):
        for interface in ("direct", "mcp"):
            for name in names:
                remaining()
                report["stage"] = phase + "-" + interface + "-" + name
                checkpoint()
                arguments = {"query": QUERIES[name], "limit": 10, "token_budget": 2048}
                started = time.monotonic()
                result = run.direct("recall", arguments) if interface == "direct" else run.tool("recall", arguments)
                elapsed = (time.monotonic() - started) * 1000
                metrics = validate_recall(result, phase == "degraded", report["expected_ids"], elapsed)
                require(metrics["trace"] not in {row["trace"] for row in report["cases"]}, "recall_trace_reused")
                report["cases"].append({"phase": phase, "interface": interface, "case": name, "query": QUERIES[name],
                                        "expected_ids": report["expected_ids"], **metrics})
                checkpoint()
                remaining()

    original = ui.read_form()
    validate_form(original, identity)
    report["configuration_before"] = form_summary(original)
    ui.screenshot(output / "provider-before.png")
    inventory = run.direct("list", {"scope": run.scope, "q": "bounded OTP", "limit": 50})
    require(inventory.get("mode") == "online", "fixture_list_offline")
    expected = {row["id"] for row in inventory.get("items", []) if isinstance(row, dict) and is_uuid(row.get("id"))
                and row.get("scope") == run.scope and isinstance(row.get("content"), str)
                and "bounded otp" in row["content"].lower() and "worker" in row["content"].lower()}
    require(expected, "fixture_preference_missing")
    report["expected_ids"] = sorted(expected)
    cases("baseline", ("exact",))
    remaining()
    fault = failure_url(original["base_url"], identity["run_id"])
    report["fault_url"] = fault

    def degraded():
        ui.screenshot(output / "provider-fault.png")
        cases("degraded", ("exact",))

    controlled_fault(ui, original, fault, degraded, report, checkpoint)
    ui.screenshot(output / "provider-restored.png")
    cases("recovered", ("exact", "paraphrase"))
    for case in report["cases"]:
        if case["phase"] != "baseline":
            remaining()
            report["stage"] = "trace-" + case["phase"] + "-" + case["interface"] + "-" + case["case"]
            checkpoint()
            report["traces"].append(observe_trace(page, case, identity, report["admin_url"], output))
            checkpoint()
    remaining()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--admin-url", default="http://127.0.0.1:4221")
    parser.add_argument("--host-url", default="http://127.0.0.1:4222")
    parser.add_argument("--timeout", type=float, default=90, help="scenario deadline, 30–300 seconds; restoration still runs after expiry")
    args = parser.parse_args()
    admin_url, host_url = local_url(args.admin_url), local_url(args.host_url)
    require(math.isfinite(args.timeout) and 30 <= args.timeout <= 300, "timeout_must_be_30_to_300_seconds")
    identity = fixture_identity(json.loads(args.fixture.read_text()))
    run = Acceptance(args.fixture, host_url, args.timeout)
    output = run.output / ("provider-recovery-" + str(time.time_ns()))
    output.mkdir(mode=0o700)
    path = output / "report.json"
    report = {"run_id": run.run_id, "phase": "provider-recovery", "status": "running-subset", "stage": "initializing",
              "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "evidence_level": "live-ui-provider-fault-and-host-recall-subset", "complete_L15": False, "complete_L01_L18": False,
              "remaining_gate": "invalid structured LLM output and asynchronous stage recovery",
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "admin_url": admin_url, "host_url": host_url, "selection": identity["selection"], "model": identity["model"],
              "timeout_seconds": args.timeout, "per_api_request_timeout_seconds": 20,
              "provider_http_status": "not exposed by the Memory API; trace class is verified in the browser",
              "restoration": {"attempted": False, "verified": False}, "cases": [], "traces": [], "page_errors": []}
    checkpoint = lambda: write_report(path, report)
    checkpoint()
    started = time.monotonic()

    def interrupt(_signum, _frame):
        raise InterruptedError("interrupted")

    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            try:
                page = browser.new_page(viewport={"width": 1440, "height": 1000})
                page.set_default_timeout(10000)
                page.on("pageerror", lambda _error: report["page_errors"].append("browser_page_error"))
                ui = ProviderUI(page, admin_url, identity)
                scenario(run, page, ui, identity, output, report, checkpoint, started + args.timeout)
                require(not report["page_errors"], "browser_page_errors_observed")
                require(report["restoration"]["verified"], "RESTORATION_NOT_PROVEN")
                report.update(status="passed-subset", stage="complete")
            finally:
                browser.close()
    except (Exception, KeyboardInterrupt) as error:
        report.update(status="failed", error=str(error) if isinstance(error, CheckError) else type(error).__name__)
    finally:
        signal.signal(signal.SIGTERM, previous)
        report["elapsed_ms"] = round((time.monotonic() - started) * 1000)
        checkpoint()
        for artifact in output.iterdir():
            os.chmod(artifact, 0o600)
    print(str(path))
    if report["restoration"]["attempted"] and not report["restoration"]["verified"]:
        print("RESTORATION_NOT_PROVEN: restore the dedicated embedding provider before further work")
    return 0 if report["status"] == "passed-subset" else 1


if __name__ == "__main__":
    raise SystemExit(main())
