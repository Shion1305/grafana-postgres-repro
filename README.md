# Grafana PostgreSQL: reproduce, patch, verify

[![Proof](https://github.com/Shion1305/grafana-postgres-repro/actions/workflows/proof.yml/badge.svg)](https://github.com/Shion1305/grafana-postgres-repro/actions/workflows/proof.yml)

**Why does “Save & test” fix a PostgreSQL dashboard without any edits—and why does the error return?**

This repository reproduces that cycle and verifies two independent OSS fixes against pinned upstream source. All data and credentials are disposable local fixtures.

## What CI proves

| Check | Before | After |
|---|---|---|
| **Browser demonstration** | Exact missing-database error; no SQL request | A real, unedited **Save & test** restores queries; replaying the original settings restores the error |
| **Grafana 12.4.1 regression** | 12 expected alias-compatibility cases fail | The same 30 cases all pass with the patch |
| **Operator 5.24.0 regression** | Identical settings change hashes and trigger unwanted PUTs | Hashes stay stable; unchanged reconciliation sends no PUT |

The browser also reapplies the corrected configuration three times and checks that the dashboard stays healthy. Direct backend `SELECT 1` succeeds throughout.

**Green CI means the expected bugs were reproduced AND the fixes passed.** Unexpected failures, compilation errors, missing tests, and an unexpectedly successful baseline fail the proof.

→ [Open the CI run](https://github.com/Shion1305/grafana-postgres-repro/actions/workflows/proof.yml) for result summaries, JSON test logs, and screenshots in the **Artifacts** section.

## The cause

1. **Grafana:** `postgres` is a supported alias, but the compatibility check uses the original type. A legacy top-level `database` never reaches `jsonData.database`, which the dashboard requires.
2. **Save & test:** opening the editor migrates that field in memory; saving persists it even when you change nothing visibly.
3. **Operator:** hashing unordered JSON makes identical desired settings appear changed. Another PUT restores the legacy representation and the error returns.

The browser uses real Grafana, PostgreSQL, and Chromium. It **replays the operator's PUT**; it does not run Kubernetes. Separate regression tests exercise the actual operator controller against a local HTTP server.

## The fixes

| Fix | File | Scope |
|---|---|---|
| Configure `jsonData.database` | [Before/after configuration](docs/explanation.md#configuration-fix) | Smallest service fix; survives repeated PUTs |
| Check the canonical datasource type | [Grafana patch](patches/grafana.patch) | Repairs legacy alias compatibility |
| Hash the serialized API command consistently | [Operator patch](patches/operator.patch) | Avoids unnecessary updates |

Tests are added **before** either source patch and are unchanged between runs. Upstream commits and Go versions are pinned in [versions.env](versions.env); container digests and browser dependencies are pinned in [demo/](demo/).

## Where to contribute upstream

**Submit two separate PRs: one to Grafana, one to Grafana Operator.** Each PR should contain its implementation change and regression tests in the upstream source tree, with a link to this repository for the browser demo and CI evidence.

### 1. Grafana: restore database fallback for SQL datasource aliases

- **Target:** [`grafana/grafana`](https://github.com/grafana/grafana), base branch **`main`**.
- **Change:** in `getFSDataSources`, check the resolved `dsDTO.Type` instead of `ds.Type` when copying the legacy database into `jsonData.database`. Preserve an explicitly configured JSON database. See [candidate patch](patches/grafana.patch).
- **Current file:** [`pkg/api/bootdata.go`](https://github.com/grafana/grafana/blob/93cdf6559b749520be0ce4b597781363a286da4d/pkg/api/bootdata.go#L341). The candidate targets **12.4.1**, where this file was named `pkg/api/frontendsettings.go`; port the change to the current path before submitting.
- **Include tests:** adapt [the SQL alias regression test](tests/grafana/frontendsettings_sql_database_test.go) into `pkg/api/bootdata_sql_database_test.go` (package `api`). Cover aliases and canonical types, missing/empty database fields, and preservation of explicit values. Pinned proof: **12 expected failures → all 30 cases pass**.

Reference [#112418](https://github.com/grafana/grafana/issues/112418) as related background: it was closed after a configuration workaround, not an alias-compatibility fix. Identify or open a focused issue for this fallback bug. After the `main` fix, ask maintainers about a backport to affected supported releases; the inspected `release-12.4.0` branch still has the original check.

### 2. Grafana Operator: make datasource hashes stable

- **Target:** [`grafana/grafana-operator`](https://github.com/grafana/grafana-operator), base branch **`master`**.
- **Change:** in [`controllers/datasource_controller.go`](https://github.com/grafana/grafana-operator/blob/4d30d715d9257007f55c41d91962306ddb92a260/controllers/datasource_controller.go#L499), hash `encoding/json.Marshal(&res)` after decoding the resolved API command, instead of hashing the order-dependent `ajson` bytes. See [candidate patch](patches/operator.patch).
- **Include tests:** adapt [the hash/controller regression tests](tests/operator/datasource_hash_test.go) into `controllers/datasource_hash_test.go`. Verify stable hashes despite key reordering, detection of real payload/credential changes, and no PUT for unchanged reconciliation. Pinned proof: **2 expected failures → all 6 cases pass**.
- **Scope:** this fixes unnecessary writes, not database-field migration or general drift detection. Changing hash formats causes one initial update. Stable comparison belongs in this controller; no `ajson` library patch is required.

### Submission readiness

Source and contribution guides checked **2026-09-15**: both relevant code patterns remain in the linked upstream commits. **CI here proves Grafana 12.4.1 and Operator 5.24.0 only.** Port and rerun each regression before/after the change on its current target branch, then run upstream checks. The patches have not been submitted upstream.

- Link the focused bug report, this repository, and the [successful proof run](https://github.com/Shion1305/grafana-postgres-repro/actions/runs/34858037519) in each PR. Keep the two fixes independent; the deployment-only `jsonData.database` workaround belongs in GitOps manifests.
- **Grafana:** follow its [PR guide](https://github.com/grafana/grafana/blob/93cdf6559b749520be0ce4b597781363a286da4d/contribute/create-pull-request.md) and [contribution requirements](https://github.com/grafana/grafana/blob/93cdf6559b749520be0ce4b597781363a286da4d/CONTRIBUTING.md): appropriate tests, signed commits, and the contributor CLA.
- **Operator:** its [contribution guide](https://github.com/grafana/grafana-operator/blob/4d30d715d9257007f55c41d91962306ddb92a260/CONTRIBUTING.md) requires `make all` and recommends `make test`. For a contributor's first three contributions, code must be primarily human-written and the PR description entirely human-written, unless maintainers grant an exception. These candidate patches/tests were AI-assisted; use them as investigation material and follow that policy when preparing the submission.

## Run it yourself

Requires Docker Compose, Node.js 24+, Python 3, Git, and Go with toolchain downloads enabled.

```sh
cd demo
npm ci
npx playwright install --with-deps chromium
docker compose up -d --wait
npm test
```

The dashboard is at [localhost:33001](http://127.0.0.1:33001). Stop the disposable stack with `docker compose down`.

From the repository root, run either source proof:

```sh
./scripts/verify-upstream.sh grafana
./scripts/verify-upstream.sh operator
```

The first source build downloads upstream dependencies and can take several minutes. Reports go to `evidence/`; checkouts go to `.work/`. Neither is committed.

[Source explanation and limits](docs/explanation.md) · [Licenses and provenance](THIRD_PARTY_NOTICES.md)
