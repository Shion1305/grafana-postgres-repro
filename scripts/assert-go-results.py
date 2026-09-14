#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reject a baseline unless go test reproduced the precise expected assertions."""

import argparse
import json
import re
import sys
from pathlib import Path


def expectations(component, phase):
    """Return every required leaf, with its expected terminal Go test action."""
    leaves = {}
    markers = {}
    if component == "grafana":
        root = "TestHTTPServer_GetFSDataSources_SQLDatabaseAliases"
        cases = ["nil_jsonData", "missing_database", "empty_database", "null_database",
                 "preserves_configured_database"]
        for plugin in ["grafana-postgresql-datasource", "mysql", "mssql"]:
            alias = "postgres" if plugin == "grafana-postgresql-datasource" else "legacy-sql-alias"
            for stored_type in [plugin, alias]:
                for case in cases:
                    name = f"{root}/{plugin}/{stored_type}/{case}"
                    fails = phase == "baseline" and stored_type == alias and case != cases[-1]
                    leaves[name] = "fail" if fails else "pass"
                    if fails:
                        markers[name] = "SQL database normalization must preserve the configured database"
        package = "github.com/grafana/grafana/pkg/api"
    else:
        package = "github.com/grafana/grafana-operator/v5/controllers"
        for case in ["credentials", "database", "jsonData", "uid"]:
            leaves[f"TestDatasourceHashChangesWithPayload/{case}"] = "pass"
        for name, marker in [
            ("TestDatasourceHashStable", "unchanged datasource must not trigger a new update"),
            ("TestUnchangedDatasourceDoesNotUpdateGrafana", "unchanged reconciliations must not overwrite Grafana"),
        ]:
            leaves[name] = "fail" if phase == "baseline" else "pass"
            if phase == "baseline":
                markers[name] = marker
    return package, leaves, markers


def validate(component, phase, exit_code, events_path, stderr_path):
    package, leaves, markers = expectations(component, phase)
    errors = []
    events = []
    try:
        for lineno, line in enumerate(events_path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                if not isinstance(event, dict) or not isinstance(event.get("Action"), str):
                    raise ValueError("missing Action")
                events.append(event)
            except (ValueError, TypeError) as exc:
                errors.append(f"Invalid go test JSON on line {lineno}: {exc}")
    except OSError as exc:
        errors.append(f"Cannot read events: {exc}")

    try:
        stderr = stderr_path.read_text()
    except OSError as exc:
        errors.append(f"Cannot read stderr: {exc}")
        stderr = ""

    expected_all = dict(leaves)
    for name in leaves:
        parts = name.split("/")
        for count in range(1, len(parts)):
            parent = "/".join(parts[:count])
            expected_all[parent] = "fail" if any(
                leaf.startswith(parent + "/") and action == "fail" for leaf, action in leaves.items()
            ) else "pass"

    terminal = {}
    ran = set()
    outputs = {}
    package_terminal = []
    all_output = stderr + "\n" + "".join(str(e.get("Output", "")) for e in events)
    if re.search(r"(?m)^(?:panic:|fatal error:|FAIL\s+.*\[(?:build failed|setup failed)\])", all_output):
        errors.append("Runtime panic or build/setup failure is not a regression assertion")

    for event in events:
        action = event["Action"]
        if action == "build-fail":
            errors.append("Go reported a build failure")
        name = event.get("Test")
        event_package = event.get("Package")
        if name:
            if event_package != package:
                errors.append(f"Test from unexpected package: {event_package}")
            if action == "run":
                if name in ran:
                    errors.append(f"Test ran more than once: {name}")
                ran.add(name)
            if action == "output":
                outputs[name] = outputs.get(name, "") + event.get("Output", "")
            if action in {"pass", "fail", "skip"}:
                if name in terminal:
                    errors.append(f"Duplicate terminal result: {name}")
                terminal[name] = action
        elif action in {"pass", "fail", "skip"} and event_package:
            if event_package != package:
                errors.append(f"Unexpected package result: {event_package}")
            package_terminal.append(action)

    if ran != set(expected_all):
        errors.append(f"Run test set differs: missing={sorted(set(expected_all) - ran)}, extra={sorted(ran - set(expected_all))}")
    if set(terminal) != set(expected_all):
        errors.append(f"Terminal test set differs: missing={sorted(set(expected_all) - set(terminal))}, extra={sorted(set(terminal) - set(expected_all))}")
    for name, expected_action in expected_all.items():
        if terminal.get(name) != expected_action:
            errors.append(f"{name}: expected {expected_action}, observed {terminal.get(name, 'missing')}")
    for name, marker in markers.items():
        if marker not in outputs.get(name, ""):
            errors.append(f"Expected regression assertion was not reached: {name}")

    expected_package_action = "fail" if phase == "baseline" else "pass"
    if package_terminal != [expected_package_action]:
        errors.append(f"Expected one package {expected_package_action}, observed {package_terminal}")
    expected_exit = 1 if phase == "baseline" else 0
    if exit_code != expected_exit:
        errors.append(f"Expected go test exit {expected_exit}, observed {exit_code}")

    observed = {name: terminal.get(name, "missing") for name in leaves}
    return {
        "schema_version": 1,
        "component": component,
        "phase": phase,
        "status": "pass" if not errors else "fail",
        "exit_code": exit_code,
        "expected_leaf_count": len(leaves),
        "passed": sum(action == "pass" for action in observed.values()),
        "failed": sum(action == "fail" for action in observed.values()),
        "skipped": sum(action == "skip" for action in observed.values()),
        "expected_failing_tests": sorted(name for name, action in leaves.items() if action == "fail"),
        "observed_failing_tests": sorted(name for name, action in observed.items() if action == "fail"),
        "tests": {name: {"expected": leaves[name], "observed": observed[name]} for name in sorted(leaves)},
        "errors": errors,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=["grafana", "operator"], required=True)
    parser.add_argument("--phase", choices=["baseline", "fixed"], required=True)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--stderr", type=Path, required=True)
    parser.add_argument("--verdict", type=Path, required=True)
    args = parser.parse_args()
    verdict = validate(args.component, args.phase, args.exit_code, args.events, args.stderr)
    args.verdict.parent.mkdir(parents=True, exist_ok=True)
    args.verdict.write_text(json.dumps(verdict, indent=2) + "\n")
    print(f"{args.component} {args.phase}: {verdict['status'].upper()} "
          f"({verdict['passed']} passed, {verdict['failed']} failed, {verdict['skipped']} skipped leaves)")
    for error in verdict["errors"]:
        print(error, file=sys.stderr)
    return 0 if verdict["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
