'use strict';
const express = require('express');
const { log, metrics, requestContext, metricsHandler } = require('./obs');

const app = express();
const PORT = Number(process.env.PORT || 3003);
const PRICING_URL = process.env.PRICING_URL || 'http://pricing-svc';
const INVENTORY_URL = process.env.INVENTORY_URL || 'http://inventory-svc';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 1500);

app.use(express.json({ limit: '50kb' }));
app.use(requestContext);

// Bounded call: a slow dependency must not hold a checkout request open indefinitely.
async function callDependency(name, url, options, requestId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const started = process.hrtime.bigint();
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal,
      headers: { 'content-type': 'application/json', 'x-request-id': requestId, ...(options.headers || {}) },
    });
    const durationMs = Number(process.hrtime.bigint() - started) / 1e6;
    if (!res.ok) {
      metrics.dependency_failures_total++;
      log('warn', 'dependency_error', { request_id: requestId, dependency: name, status: res.status, duration_ms: Number(durationMs.toFixed(1)) });
      return { ok: false, reason: `status_${res.status}` };
    }
    log('info', 'dependency_call', { request_id: requestId, dependency: name, status: res.status, duration_ms: Number(durationMs.toFixed(1)) });
    return { ok: true, body: await res.json() };
  } catch (err) {
    const durationMs = Number(process.hrtime.bigint() - started) / 1e6;
    metrics.dependency_failures_total++;
    const reason = err.name === 'AbortError' ? 'timeout' : 'unreachable';
    log('warn', 'dependency_error', { request_id: requestId, dependency: name, error: reason, duration_ms: Number(durationMs.toFixed(1)) });
    return { ok: false, reason };
  } finally {
    clearTimeout(timer);
  }
}

app.get('/live', (_req, res) => res.json({ ok: true }));

// Readiness deliberately excludes pricing/inventory. Probing dependencies here would remove every
// checkout replica from the Service during a dependency outage, converting partial failure into
// total unavailability (see Lecture 10, health-check cascading failure).
app.get('/health', (_req, res) => res.json({ ok: true }));

app.get('/metrics', metricsHandler);

app.post('/checkout', async (req, res) => {
  const requestId = req.requestId;
  const subtotal = Number(req.body?.subtotal);
  const sku = Number(req.body?.sku);
  if (!Number.isFinite(subtotal) || subtotal < 0) return res.status(400).json({ error: 'subtotal must be a non-negative number' });
  if (!Number.isInteger(sku)) return res.status(400).json({ error: 'sku must be an integer' });

  const [pricing, inventory] = await Promise.all([
    callDependency('pricing', `${PRICING_URL}/price`, { method: 'POST', body: JSON.stringify({ subtotal }) }, requestId),
    callDependency('inventory', `${INVENTORY_URL}/stock/${sku}`, { method: 'GET' }, requestId),
  ]);

  // Pricing is on the critical path: without a total there is no order to place.
  if (!pricing.ok) {
    log('error', 'checkout_failed', { request_id: requestId, reason: `pricing_${pricing.reason}` });
    return res.status(503).json({ error: 'checkout unavailable', reason: `pricing_${pricing.reason}`, requestId });
  }

  // Inventory is not: we degrade to an unconfirmed stock status rather than reject the customer.
  if (!inventory.ok) {
    metrics.degraded_responses_total++;
    log('warn', 'checkout_degraded', { request_id: requestId, reason: `inventory_${inventory.reason}` });
    return res.status(200).json({
      status: 'accepted_pending_stock_confirmation',
      degraded: true,
      degradedComponent: 'inventory',
      pricing: pricing.body,
      stock: { sku, inStock: null, confirmed: false },
      requestId,
    });
  }

  return res.json({
    status: inventory.body.inStock ? 'confirmed' : 'out_of_stock',
    degraded: false,
    pricing: pricing.body,
    stock: { sku, inStock: inventory.body.inStock, confirmed: true },
    requestId,
  });
});

app.listen(PORT, () => log('info', 'service_started', { port: PORT, pricing_url: PRICING_URL, inventory_url: INVENTORY_URL, timeout_ms: TIMEOUT_MS }));
