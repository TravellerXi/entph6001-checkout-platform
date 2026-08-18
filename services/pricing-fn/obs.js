'use strict';
// Shared observability helpers: structured JSON logs, request-ID propagation, counters.
const crypto = require('crypto');

const SERVICE = process.env.SERVICE_NAME || 'unknown';

function log(level, event, fields = {}) {
  process.stdout.write(JSON.stringify({
    ts: new Date().toISOString(),
    level,
    service: SERVICE,
    event,
    ...fields,
  }) + '\n');
}

const metrics = {
  requests_total: 0,
  errors_total: 0,
  dependency_failures_total: 0,
  degraded_responses_total: 0,
};

function requestContext(req, res, next) {
  // Reuse an inbound correlation ID so one checkout can be traced across every hop.
  req.requestId = req.header('x-request-id') || crypto.randomUUID();
  res.setHeader('x-request-id', req.requestId);
  const started = process.hrtime.bigint();
  metrics.requests_total++;
  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - started) / 1e6;
    if (res.statusCode >= 500) metrics.errors_total++;
    log('info', 'http_request', {
      request_id: req.requestId,
      method: req.method,
      route: req.path,
      status: res.statusCode,
      duration_ms: Number(durationMs.toFixed(1)),
    });
  });
  next();
}

function metricsHandler(_req, res) {
  const body = Object.entries(metrics).map(([k, v]) => `${k} ${v}`).join('\n');
  res.set('Content-Type', 'text/plain; charset=utf-8').send(body + '\n');
}

module.exports = { log, metrics, requestContext, metricsHandler };
