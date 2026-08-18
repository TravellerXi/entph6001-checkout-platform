'use strict';
const express = require('express');
const { Pool } = require('pg');
const { log, metrics, requestContext, metricsHandler } = require('./obs');

const app = express();
const PORT = Number(process.env.PORT || 3002);
const DELAY_MS = Number(process.env.DELAY_MS || 0);

// Credentials arrive from a Secret; host/db/user from a ConfigMap. Nothing is baked into the image.
const pool = new Pool({
  host: process.env.PGHOST || 'postgres-svc',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'shop',
  user: process.env.PGUSER || 'shop',
  password: process.env.PGPASSWORD || '',
  max: Number(process.env.PGPOOL_MAX || 5),
  connectionTimeoutMillis: Number(process.env.PGCONNECT_TIMEOUT_MS || 2000),
});

let schemaReady = false;

async function initSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS stock (
      sku INTEGER PRIMARY KEY,
      in_stock BOOLEAN NOT NULL
    )`);
  await pool.query(`
    INSERT INTO stock (sku, in_stock) VALUES (1, true), (2, true), (3, false)
    ON CONFLICT (sku) DO NOTHING`);
  schemaReady = true;
  log('info', 'schema_ready', {});
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

app.use(express.json({ limit: '50kb' }));
app.use(requestContext);

app.get('/live', (_req, res) => res.json({ ok: true }));

// Readiness DOES check the database: without its own datastore this service cannot answer at all.
app.get('/health', async (_req, res) => {
  if (!schemaReady) return res.status(503).json({ ok: false, reason: 'schema not initialised' });
  try {
    await pool.query('SELECT 1');
    return res.json({ ok: true });
  } catch (err) {
    metrics.dependency_failures_total++;
    return res.status(503).json({ ok: false, reason: 'database unreachable' });
  }
});

app.get('/metrics', metricsHandler);

app.get('/stock/:sku', async (req, res) => {
  if (DELAY_MS > 0) await sleep(DELAY_MS);
  const sku = Number(req.params.sku);
  if (!Number.isInteger(sku)) return res.status(400).json({ error: 'sku must be an integer' });
  try {
    const { rows } = await pool.query('SELECT in_stock FROM stock WHERE sku = $1', [sku]);
    if (rows.length === 0) return res.status(404).json({ error: 'unknown sku' });
    return res.json({ sku, inStock: rows[0].in_stock });
  } catch (err) {
    metrics.dependency_failures_total++;
    log('error', 'database_error', { request_id: req.requestId, error: err.message });
    return res.status(503).json({ error: 'inventory datastore unavailable' });
  }
});

// Retry schema init instead of crash-looping: the database may still be starting.
(async function start() {
  for (let attempt = 1; attempt <= 30 && !schemaReady; attempt++) {
    try {
      await initSchema();
    } catch (err) {
      log('warn', 'schema_init_retry', { attempt, error: err.message });
      await sleep(2000);
    }
  }
  app.listen(PORT, () => log('info', 'service_started', { port: PORT, delay_ms: DELAY_MS }));
})();
