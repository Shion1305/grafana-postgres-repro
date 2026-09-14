# How the failure and fixes fit together

## Grafana: a skipped compatibility conversion

In Grafana 12.4.1, the [frontend settings builder](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/pkg/api/frontendsettings.go#L522) resolves the `postgres` alias and sets `dsDTO.Type` to the canonical plugin ID. Its [database fallback](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/pkg/api/frontendsettings.go#L588) nevertheless compares the original `ds.Type`.

The SQL frontend then [rejects the query](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/packages/grafana-sql/src/datasource/SqlDatasource.ts#L127) because `jsonData.database` is missing. The backend [still accepts the legacy database field](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/pkg/tsdb/grafana-postgresql-datasource/postgres.go#L101), which explains why direct `SELECT 1` succeeds.

The [editor migration](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/packages/grafana-sql/src/components/configuration/useMigrateDatabaseFields.ts#L22) moves the database field when the settings page opens. [Save & test](https://github.com/grafana/grafana/blob/46a02dc12a085445ab105b72fa159248f7d1dc9d/public/app/features/datasources/components/EditDataSource.tsx#L137) saves before testing, so “no edits” does not mean “identical API payload.”

**Patch:** use `dsDTO.Type` in the compatibility check. The same upstream regression test covers canonical and alias types, nil/missing/null/empty JSON database values, and preservation of explicit JSON values. Of 30 scenarios, the 12 alias fallback cases must fail before the patch; all 30 must pass afterward.

## Operator: unstable hashes cause repeated updates

Operator 5.24.0 [skips updates when its desired-state hash matches](https://github.com/grafana/grafana-operator/blob/065a718a1fe83728d08054c299de7f8577e88f79/controllers/datasource_controller.go#L296). However, it [hashes bytes from `ajson.Marshal`](https://github.com/grafana/grafana-operator/blob/065a718a1fe83728d08054c299de7f8577e88f79/controllers/datasource_controller.go#L440) after modifying the object. The dependency [iterates an unsorted map](https://github.com/spyzhov/ajson/blob/1f0ecf9280c56ba64e5ce1883d90594ef588e751/encode.go#L63), so equivalent objects can produce different hashes.

**Patch:** hash `encoding/json` serialization of the typed API command. Tests invoke the real builder and controller: repeated inputs remain stable, key reordering is harmless, credential/database/settings/UID changes still count, and an unchanged reconciliation sends no PUT.

The [default resynchronization period is 10 minutes](https://github.com/grafana/grafana-operator/blob/065a718a1fe83728d08054c299de7f8577e88f79/main.go#L95). The CI proof accelerates the relevant controller calls and payload replay; it does not wait for that timer.

## Configuration fix

Move the database name into `jsonData`; the `postgres` alias can remain:

```diff
 type: postgres
-database: fixture
 jsonData:
+  database: fixture
   sslmode: disable
```

Here `sslmode: disable` is only for the disposable local database. The fix itself is the database field move; preserve the TLS settings of any existing deployment.

This configuration correction fixes the browser behavior even without rebuilding either project. The operator source patch alone does not migrate existing datasource settings.

## What the evidence does—and does not—establish

- **Browser:** real shipped Grafana 12.4.1 + PostgreSQL + Chromium; actual no-edit Save & test; legacy PUT replay; repeated corrected PUTs. No live Kubernetes operator is running in this demonstration.
- **Source patches:** actual upstream regression tests, added to pristine pinned commits and run both before and after fix-only patches. Tests, source revision, and toolchain stay identical between phases.
- **Failure classification:** the verifier requires the precise expected test outcomes. A compiler, network, dependency, or unrelated test failure cannot stand in for reproducing the bug.
- **Scope:** targeted regression tests, not complete upstream suites or rebuilt patched Grafana containers. These are candidate patches, not claims of upstream acceptance.
- **Operator behavior:** switching hash formats causes an initial update. The existing unchanged-hash shortcut does not independently detect edits made only in Grafana; this patch does not add drift detection.

An earlier [upstream report](https://github.com/grafana/grafana/issues/112418) describes the same missing-database error and configuration workaround. This repository supplies reproducible evidence using dummy data, independently of any production environment.
