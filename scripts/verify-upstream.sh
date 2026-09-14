#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../versions.env
source "$ROOT_DIR/versions.env"
COMPONENT=${1:-}
case "$COMPONENT" in
  grafana)
    REPOSITORY=$GRAFANA_REPOSITORY TAG=$GRAFANA_TAG SOURCE_SHA=$GRAFANA_SHA GO_VERSION=$GRAFANA_GO_VERSION
    IMPLEMENTATION=pkg/api/frontendsettings.go
    TEST_FILENAME=frontendsettings_sql_database_test.go
    TEST_DESTINATION=pkg/api/$TEST_FILENAME
    GO_PACKAGE=./pkg/api
    TEST_PATTERN='^TestHTTPServer_GetFSDataSources_SQLDatabaseAliases$'
    ;;
  operator)
    REPOSITORY=$OPERATOR_REPOSITORY TAG=$OPERATOR_TAG SOURCE_SHA=$OPERATOR_SHA GO_VERSION=$OPERATOR_GO_VERSION
    IMPLEMENTATION=controllers/datasource_controller.go
    TEST_FILENAME=datasource_hash_test.go
    TEST_DESTINATION=controllers/$TEST_FILENAME
    GO_PACKAGE=./controllers
    TEST_PATTERN='^(TestDatasourceHashStable|TestDatasourceHashChangesWithPayload|TestUnchangedDatasourceDoesNotUpdateGrafana)$'
    ;;
  *) printf 'Usage: %s grafana|operator\n' "$0" >&2; exit 2 ;;
esac

CHECKOUT_DIR=$ROOT_DIR/.work/$COMPONENT
EVIDENCE_DIR=$ROOT_DIR/evidence/$COMPONENT
PATCH_FILE=$ROOT_DIR/patches/$COMPONENT.patch
TEST_FILE=$ROOT_DIR/tests/$COMPONENT/$TEST_FILENAME
STAGE=setup

# Only the generated scratch checkout is managed. Refuse redirected locations.
for directory in "$ROOT_DIR/.work" "$CHECKOUT_DIR" "$ROOT_DIR/evidence" "$EVIDENCE_DIR"; do
  if [[ -L "$directory" ]]; then
    printf 'Refusing symlinked generated directory: %s\n' "$directory" >&2
    exit 2
  fi
done
mkdir -p "$ROOT_DIR/.work" "$EVIDENCE_DIR"

on_exit() {
  local exit_status=$1
  if (( exit_status != 0 )); then
    python3 - "$EVIDENCE_DIR" "$COMPONENT" "$STAGE" "$exit_status" <<'PY'
import json, sys
from pathlib import Path
folder, component, stage, code = sys.argv[1:]
result = {"schema_version": 1, "component": component, "status": "fail", "stage": stage,
          "errors": [f"Verification stopped during {stage} (exit {code}); no passing proof was produced."]}
for phase in ("baseline", "fixed"):
    file = Path(folder) / f"{phase}-verdict.json"
    if file.exists():
        result[phase] = json.loads(file.read_text())
(Path(folder) / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
PY
  fi
}
trap 'on_exit "$?"' EXIT

# Replace only this runner's previous result files, so a failed rerun cannot expose
# an earlier passing verdict as its result.
python3 - "$EVIDENCE_DIR" "$COMPONENT" <<'PY'
import json, sys
from pathlib import Path
folder, component = Path(sys.argv[1]), sys.argv[2]
for phase in ("baseline", "fixed"):
    for suffix in ("jsonl", "stderr.log"):
        (folder / f"{phase}.{suffix}").write_text("")
    (folder / f"{phase}-verdict.json").write_text(json.dumps({"status": "not-run", "phase": phase}) + "\n")
(folder / "verdict.json").write_text(json.dumps({"schema_version": 1, "component": component, "status": "running"}) + "\n")
PY

prepare_checkout() {
  [[ $(git apply --numstat "$PATCH_FILE" | awk '{print $3}') == "$IMPLEMENTATION" ]]
  if [[ ! -e "$CHECKOUT_DIR" ]]; then
    # A local object cache speeds development. The fetch URL is always official,
    # and neither modifications nor untracked tests from the cache are copied.
    if [[ -n ${UPSTREAM_SOURCE_CACHE:-} ]]; then
      git clone --filter=blob:none --depth 1 --branch "$TAG" --no-checkout \
        --reference-if-able "$UPSTREAM_SOURCE_CACHE" "$REPOSITORY" "$CHECKOUT_DIR"
    else
      git clone --filter=blob:none --depth 1 --branch "$TAG" --no-checkout \
        "$REPOSITORY" "$CHECKOUT_DIR"
    fi
    if [[ "$COMPONENT" == grafana ]]; then
      git -C "$CHECKOUT_DIR" sparse-checkout init --cone
      git -C "$CHECKOUT_DIR" sparse-checkout set apps pkg conf
    fi
    git -C "$CHECKOUT_DIR" checkout --detach "$SOURCE_SHA"
    printf '%s:%s\n' "$COMPONENT" "$SOURCE_SHA" > "$CHECKOUT_DIR/.git/repro-managed"
  fi
  if [[ ! -d "$CHECKOUT_DIR/.git" || -L "$CHECKOUT_DIR/.git" || ! -f "$CHECKOUT_DIR/.git/repro-managed" ]]; then
    printf 'Refusing an unmarked checkout: %s\n' "$CHECKOUT_DIR" >&2
    return 1
  fi
  [[ $(cat "$CHECKOUT_DIR/.git/repro-managed") == "$COMPONENT:$SOURCE_SHA" ]]
  [[ $(git -C "$CHECKOUT_DIR" rev-parse HEAD) == "$SOURCE_SHA" ]]
  # Inspect the recorded URL before the user's optional HTTPS-to-SSH rewrite.
  [[ $(git -C "$CHECKOUT_DIR" config --get remote.origin.url) == "$REPOSITORY" ]]
  git -C "$CHECKOUT_DIR" diff --cached --quiet
  if ! git -C "$CHECKOUT_DIR" diff --quiet; then
    # A rerun may undo only our known fix. Other edits are retained and rejected.
    [[ $(git -C "$CHECKOUT_DIR" diff --name-only) == "$IMPLEMENTATION" ]]
    git -C "$CHECKOUT_DIR" apply --reverse --check "$PATCH_FILE"
    git -C "$CHECKOUT_DIR" apply --reverse "$PATCH_FILE"
  fi
  git -C "$CHECKOUT_DIR" diff --quiet
  local untracked
  untracked=$(git -C "$CHECKOUT_DIR" ls-files --others --exclude-standard)
  [[ -z "$untracked" || "$untracked" == "$TEST_DESTINATION" ]]
  [[ -z $(git -C "$CHECKOUT_DIR" ls-files -- "$TEST_DESTINATION") ]]
  [[ ! -L "$CHECKOUT_DIR/$TEST_DESTINATION" ]]
  cp "$TEST_FILE" "$CHECKOUT_DIR/$TEST_DESTINATION"
  git -C "$CHECKOUT_DIR" apply --check "$PATCH_FILE"
  printf 'Source: %s %s (%s)\n' "$REPOSITORY" "$TAG" "$SOURCE_SHA"
}
prepare_checkout 2>&1 | tee "$EVIDENCE_DIR/setup.log"

export GOTOOLCHAIN=go$GO_VERSION
if [[ "$COMPONENT" == grafana ]]; then
  export GOWORK=$CHECKOUT_DIR/go.work
else
  export GOWORK=off
fi
STAGE=toolchain
ACTUAL_TOOLCHAIN=$(cd "$CHECKOUT_DIR" && go env GOVERSION)
[[ "$ACTUAL_TOOLCHAIN" == "go$GO_VERSION" ]]
printf 'Toolchain: %s\n' "$ACTUAL_TOOLCHAIN" | tee -a "$EVIDENCE_DIR/setup.log"

run_phase() {
  local phase=$1 go_status
  STAGE=$phase
  cmp "$TEST_FILE" "$CHECKOUT_DIR/$TEST_DESTINATION"
  if [[ "$phase" == baseline ]]; then
    git -C "$CHECKOUT_DIR" diff --quiet
  else
    [[ $(git -C "$CHECKOUT_DIR" diff --name-only) == "$IMPLEMENTATION" ]]
  fi
  printf 'Running %s %s regression...\n' "$COMPONENT" "$phase"
  if (cd "$CHECKOUT_DIR" && go test -json -count=1 -timeout=10m -run "$TEST_PATTERN" "$GO_PACKAGE") \
      > "$EVIDENCE_DIR/$phase.jsonl" 2> "$EVIDENCE_DIR/$phase.stderr.log"; then
    go_status=0
  else
    go_status=$?
  fi
  python3 "$ROOT_DIR/scripts/assert-go-results.py" \
    --component "$COMPONENT" --phase "$phase" --exit-code "$go_status" \
    --events "$EVIDENCE_DIR/$phase.jsonl" --stderr "$EVIDENCE_DIR/$phase.stderr.log" \
    --verdict "$EVIDENCE_DIR/$phase-verdict.json"
}

run_phase baseline
STAGE=apply-fix
# The regression test is already present and remains identical in both phases.
git -C "$CHECKOUT_DIR" apply "$PATCH_FILE"
run_phase fixed

STAGE=summary
cmp "$TEST_FILE" "$CHECKOUT_DIR/$TEST_DESTINATION"
[[ $(git -C "$CHECKOUT_DIR" diff --name-only) == "$IMPLEMENTATION" ]]
python3 - "$EVIDENCE_DIR" "$COMPONENT" "$REPOSITORY" "$TAG" "$SOURCE_SHA" "$ACTUAL_TOOLCHAIN" "$PATCH_FILE" "$TEST_FILE" <<'PY'
import hashlib, json, sys
from pathlib import Path
folder, component, repo, tag, sha, toolchain, patch, test = sys.argv[1:]
folder = Path(folder)
phases = {name: json.loads((folder / f"{name}-verdict.json").read_text()) for name in ("baseline", "fixed")}
assert all(value["status"] == "pass" for value in phases.values())
result = {"schema_version": 1, "component": component, "status": "pass",
          "source": {"repository": repo, "tag": tag, "sha": sha}, "toolchain": toolchain,
          "inputs": {"patch_sha256": hashlib.sha256(Path(patch).read_bytes()).hexdigest(),
                     "regression_test_sha256": hashlib.sha256(Path(test).read_bytes()).hexdigest()},
          **phases, "errors": []}
(folder / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
print(f"{component}: PASS — expected baseline assertions failed; all fixed assertions passed.")
PY
