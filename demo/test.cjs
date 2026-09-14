#!/usr/bin/env node
// Grafana UI, API, datasource backend, and PostgreSQL are real.
// Only the operator's scheduling of reconciliation is emulated by direct PUTs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { chromium } = require('playwright');

const port = Number(process.env.GRAFANA_PORT || 33001);
assert.ok(Number.isInteger(port) && port > 0 && port <= 65535, 'GRAFANA_PORT must be a valid port');
// A host override is deliberately not supported: this test writes only to loopback.
const base = `http://127.0.0.1:${port}`;
const uid = 'postgres-demo';
const dashboardUid = 'postgres-database-field-demo';
const evidence = path.resolve(__dirname, '..', 'evidence', 'demo');
const auth = Buffer.from('demo-admin:local-demo-grafana-password').toString('base64');
const before = JSON.parse(fs.readFileSync(path.join(__dirname, 'config/before.json'), 'utf8'));
const after = JSON.parse(fs.readFileSync(path.join(__dirname, 'config/after.json'), 'utf8'));
const errorText = 'You do not currently have a default database configured for this data source. Postgres requires a default database with which to connect. Please configure one through the Data Sources Configuration page, or if you are using a provisioning file, update that configuration file with a default database.';
const report = {
  operatorReconciliation: 'Direct replay of legacy/corrected API payloads; no Kubernetes operator is running',
  sql: 'SELECT 1 AS healthy',
  stages: [],
};

async function api(method, route, body) {
  const response = await fetch(base + route, {
    method,
    headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  return { status: response.status, body: await response.json() };
}

async function waitReady() {
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const health = await api('GET', '/api/health');
      if (health.status === 200) {
        assert.equal(health.body.version, '12.4.1', 'This reproduction pins Grafana 12.4.1');
        return health.body;
      }
    } catch (error) {
      if (error instanceof assert.AssertionError) throw error;
    }
    await delay(1000);
  }
  throw new Error(`Grafana did not become ready at ${base}`);
}

function fields(ds) {
  // Deliberately exclude credentials and unrelated account metadata from evidence.
  return { type: ds.type, database: ds.database ?? null, jsonData: ds.jsonData, version: ds.version };
}

async function datasource() {
  const result = await api('GET', `/api/datasources/uid/${uid}`);
  assert.equal(result.status, 200, 'Datasource GET must succeed');
  return result.body;
}

async function applyConfiguration(configuration) {
  const payload = structuredClone(configuration);
  assert.equal(payload.uid, uid);
  assert.equal(payload.url, 'postgres:5432');
  const existing = await api('GET', `/api/datasources/uid/${uid}`);
  assert.ok([200, 404].includes(existing.status), `Unexpected datasource status ${existing.status}`);
  let result;
  if (existing.status === 404) {
    result = await api('POST', '/api/datasources', payload);
  } else {
    payload.id = existing.body.id;
    payload.orgId = existing.body.orgId;
    result = await api('PUT', `/api/datasources/uid/${uid}`, payload);
  }
  assert.equal(result.status, 200, `Datasource write failed: ${JSON.stringify(result.body)}`);
}

async function query(sql = report.sql) {
  const result = await api('POST', '/api/ds/query', {
    from: '0', to: '1000',
    queries: [{ refId: 'A', datasource: { type: 'postgres', uid },
      format: 'table', rawQuery: true, rawSql: sql, intervalMs: 1000, maxDataPoints: 100 }],
  });
  assert.equal(result.status, 200, `Backend SQL HTTP error: ${JSON.stringify(result.body)}`);
  const answer = result.body.results.A;
  assert.ok(!answer.error, `Backend SQL error: ${answer.error}`);
  return answer.frames[0].data.values;
}

async function createDashboard() {
  const result = await api('POST', '/api/dashboards/db', {
    overwrite: true,
    dashboard: {
      id: null, uid: dashboardUid, title: 'PostgreSQL database field compatibility',
      schemaVersion: 39, version: 0, time: { from: 'now-6h', to: 'now' },
      panels: [{ id: 1, type: 'table', title: 'Dummy SELECT 1',
        gridPos: { x: 0, y: 0, w: 24, h: 10 }, datasource: { type: 'postgres', uid },
        targets: [{ refId: 'A', datasource: { type: 'postgres', uid },
          format: 'table', rawQuery: true, rawSql: report.sql }], options: { showHeader: true } }],
    },
  });
  assert.equal(result.status, 200, `Dashboard creation failed: ${JSON.stringify(result.body)}`);
}

async function main() {
  fs.mkdirSync(evidence, { recursive: true });
  const started = Date.now();
  let browser;
  let activePage;
  try {
    const health = await waitReady();
    await applyConfiguration(before);
    await createDashboard();
    const postgresVersion = (await query("SELECT current_setting('server_version') AS server_version"))[0][0];
    assert.match(postgresVersion, /^17\./, 'This reproduction uses PostgreSQL 17');
    const launch = { headless: true };
    if (process.env.CHROME_PATH) launch.executablePath = process.env.CHROME_PATH;
    browser = await chromium.launch(launch);
    report.versions = { grafana: health.version, grafanaCommit: health.commit,
      postgres: postgresVersion, node: process.version,
      playwright: require('playwright/package.json').version, chromium: browser.version() };

    async function newPage() {
      const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
      page.setDefaultTimeout(20000);
      activePage = page;
      return page;
    }

    async function dashboardState(label, expectedError) {
      assert.deepEqual(await query(), [[1]], 'Real backend SELECT 1 must stay healthy in every state');
      const page = await newPage();
      const frontendQueries = [];
      page.on('request', request => {
        const url = new URL(request.url());
        if (url.origin === base && url.pathname === '/api/ds/query') frontendQueries.push(request);
      });
      await page.goto(`${base}/d/${dashboardUid}`);
      if (expectedError) {
        await page.getByRole('button', { name: 'Panel status', exact: true }).click();
        await page.getByText(errorText, { exact: true }).waitFor({ state: 'visible' });
        assert.equal(frontendQueries.length, 0, 'The failing frontend must block before sending SQL');
      } else {
        await page.getByRole('gridcell', { name: '1', exact: true }).waitFor({ state: 'visible' });
        assert.equal(await page.getByRole('button', { name: 'Panel status', exact: true }).count(), 0);
        assert.ok(frontendQueries.length > 0, 'The healthy frontend must actually send SQL');
      }
      const snapshot = fields(await datasource());
      if (expectedError) {
        assert.equal(snapshot.database, 'demo');
        assert.equal(snapshot.jsonData.database, undefined);
      } else {
        assert.equal(snapshot.jsonData.database, 'demo');
      }
      const stage = { label, result: expectedError ? 'exact missing-default-database error' : 'healthy = 1',
        frontendQueryCount: frontendQueries.length, backendSelect1: 1, datasource: snapshot };
      if (expectedError) stage.error = errorText;
      report.stages.push(stage);
      await page.screenshot({ path: path.join(evidence, `${label}.png`), fullPage: true });
      await page.close();
      activePage = undefined;
      console.log(`PASS ${label}: ${stage.result}; frontend SQL requests=${frontendQueries.length}; backend SELECT 1=1`);
    }

    await dashboardState('01-legacy-error', true);

    const settings = await newPage();
    let submitted;
    settings.on('request', request => {
      if (request.method() === 'PUT' && new URL(request.url()).pathname === `/api/datasources/uid/${uid}`) {
        submitted = fields(request.postDataJSON());
      }
    });
    await settings.goto(`${base}/connections/datasources/edit/${uid}`);
    assert.equal(await settings.getByRole('textbox', { name: 'Database', exact: true }).inputValue(), 'demo');
    // Do not fill, select, or toggle any field: this exercises the reported no-edits recovery.
    await settings.getByRole('button', { name: 'Save & test', exact: true }).click();
    await settings.getByText('Database Connection OK', { exact: true }).waitFor({ state: 'visible' });
    assert.equal(submitted.database, '');
    assert.equal(submitted.jsonData.database, 'demo');
    report.stages.push({ label: 'actual-ui-save-and-test', editedFields: 0, submitted });
    await settings.screenshot({ path: path.join(evidence, 'ui-save-and-test.png'), fullPage: true });
    await settings.close();
    activePage = undefined;
    await dashboardState('02-healthy-after-save', false);

    await applyConfiguration(before);
    await dashboardState('03-recurrence-after-legacy-put', true);

    for (let iteration = 1; iteration <= 3; iteration++) {
      await applyConfiguration(after);
      const stored = await datasource();
      assert.equal(stored.database, '', 'Reapplying corrected configuration must not restore the old database field');
      assert.equal(stored.jsonData.database, 'demo', 'Reapplying corrected configuration must retain the JSON database');
      await dashboardState(`0${iteration + 3}-fixed-put-${iteration}`, false);
    }
    report.result = 'PASS: bug reproduced, unchanged UI save recovered, legacy PUT recurred, corrected payload stayed healthy after three PUTs';
    console.log(report.result);
    if (process.env.GITHUB_STEP_SUMMARY) {
      fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
        '### Real Grafana/PostgreSQL browser demo\n\n' +
        '- Exact missing-database error reproduced; direct backend SQL stayed healthy.\n' +
        '- Actual **Save & test**, with zero field edits, recovered the dashboard.\n' +
        '- Replaying the legacy API payload reproduced the same error.\n' +
        '- Corrected `jsonData.database` stayed healthy through **three** updates.\n' +
        '- Operator scheduling is emulated; Grafana, its browser UI, and PostgreSQL are real.\n\n');
    }
  } catch (error) {
    report.result = 'FAIL';
    report.error = error.stack || String(error);
    if (activePage) {
      await activePage.screenshot({ path: path.join(evidence, 'failure.png'), fullPage: true }).catch(() => {});
    }
    throw error;
  } finally {
    report.elapsedSeconds = +((Date.now() - started) / 1000).toFixed(3);
    fs.writeFileSync(path.join(evidence, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    if (browser) await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
