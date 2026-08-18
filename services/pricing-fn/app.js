'use strict';
const express = require('express');
const { log, requestContext, metricsHandler } = require('./obs');

const app = express();
const PORT = Number(process.env.PORT || 3001);
const DELAY_MS = Number(process.env.DELAY_MS || 0);
const TAX_RATE = Number(process.env.TAX_RATE || 0.23);

app.use(express.json({ limit: '50kb' }));
app.use(requestContext);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Liveness stays shallow on purpose: a slow dependency must never restart this process.
app.get('/live', (_req, res) => res.json({ ok: true }));
app.get('/health', (_req, res) => res.json({ ok: true }));
app.get('/metrics', metricsHandler);

app.post('/price', async (req, res) => {
  if (DELAY_MS > 0) await sleep(DELAY_MS);
  const subtotal = Number(req.body?.subtotal);
  if (!Number.isFinite(subtotal) || subtotal < 0) {
    return res.status(400).json({ error: 'subtotal must be a non-negative number' });
  }
  const tax = Number((subtotal * TAX_RATE).toFixed(2));
  return res.json({
    subtotal,
    taxRate: TAX_RATE,
    tax,
    total: Number((subtotal + tax).toFixed(2)),
  });
});

app.listen(PORT, () => log('info', 'service_started', { port: PORT, delay_ms: DELAY_MS }));
