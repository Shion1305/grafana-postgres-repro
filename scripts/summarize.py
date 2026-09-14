#!/usr/bin/env python3
"""Render the verifier's verdict; never infer success from an exit code alone."""
import json
import os
from pathlib import Path
import sys

component = sys.argv[1]
if component not in {"grafana", "operator"}:
    raise SystemExit("Expected grafana or operator")
path = Path(__file__).resolve().parents[1] / "evidence" / component / "verdict.json"
lines = [f"### {component.title()}: baseline and patch", ""]
if not path.exists():
    lines += ["No verified result was produced. Inspect the failed setup step."]
else:
    verdict = json.loads(path.read_text())
    lines += [f"**Verifier result: {verdict['status'].upper()}**", "",
              "| Phase | Passing cases | Failing cases | Verification |",
              "|---|---:|---:|---|"]
    for label in ("baseline", "fixed"):
        phase = verdict.get(label) or {}
        lines.append(f"| {label.title()} | {phase.get('passed', '—')} | "
                     f"{phase.get('failed', '—')} | {phase.get('status', 'not reached')} |")
    lines += ["", "Baseline verification succeeds only for the specified regression failures; "
              "fixed verification requires the same tests to pass.", ""]
    if "source" in verdict:
        lines.append(f"Pinned upstream commit: `{verdict['source']['sha']}`.")
    for error in verdict.get("errors", []):
        lines.append(f"- {error}")
text = "\n".join(lines) + "\n"
print(text)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(text)
