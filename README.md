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
