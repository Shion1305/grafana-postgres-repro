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

## Upstream contributions

Two independent PRs are open, each with its implementation change and regression tests:

| Project | Issue | PR | Upstream change |
|---|---|---|---|
| **Grafana** (`main`) | [#132582](https://github.com/grafana/grafana/issues/132582) | [#132583](https://github.com/grafana/grafana/pull/132583) | Use the resolved plugin type for the database fallback in `pkg/api/bootdata.go` |
| **Grafana Operator** (`master`) | [#2953](https://github.com/grafana/grafana-operator/issues/2953) | [#2954 — draft](https://github.com/grafana/grafana-operator/pull/2954) | Hash the resolved API command consistently in `controllers/datasource_controller.go` |

### Validation against current upstream source

Checked locally on **2026-09-15**, separately from this repository's pinned-version CI:

- **Grafana**, base [`93cdf6559b74`](https://github.com/grafana/grafana/commit/93cdf6559b749520be0ce4b597781363a286da4d): four PostgreSQL alias cases fail before the fix; all **10 regression cases** and **18 existing frontend-settings cases** pass afterward. Covers both PostgreSQL type names, absent/empty database values, and preservation of explicit settings. Package lint passes.
- **Operator**, base [`4d30d715d925`](https://github.com/grafana/grafana-operator/commit/4d30d715d9257007f55c41d91962306ddb92a260): two failures reproduce unstable hashes and an unwanted PUT; all **six regression cases** pass afterward. Checks also cover reordered JSON keys and real configuration/credential changes. `go test -short ./...` and `make all` pass, including integration tests, lint, vet, and generated-file checks. The full run used an isolated Docker config for public images to avoid a local credential-helper stall.

The [Grafana patch here](patches/grafana.patch) intentionally retains the **12.4.1** filename, `pkg/api/frontendsettings.go`; the upstream PR uses its current name, `pkg/api/bootdata.go`. The [successful CI proof](https://github.com/Shion1305/grafana-postgres-repro/actions/runs/34858037519) continues to test **Grafana 12.4.1 and Operator 5.24.0**. Upstream PR checks are tracked on the linked PRs.

### Scope and submission status

- **Grafana:** fixes the frontend database fallback without rewriting stored configuration. A backport to affected supported releases remains a maintainer decision.
- **Operator:** prevents unnecessary writes. Its hash format changes once, causing one initial update; it does not migrate database fields or add general drift detection. No `ajson` library patch is needed.
- Both PRs use signed commits and require a contributor CLA. The Operator PR is a draft requesting the explicit maintainer exception allowed by its [AI contribution policy](https://github.com/grafana/grafana-operator/blob/master/CONTRIBUTING.md#usage-of-generative-ai); no exception has been granted.

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
