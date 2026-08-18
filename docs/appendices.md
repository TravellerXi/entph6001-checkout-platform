# Appendices — Evidence

Every figure quoted in the report comes from one of the log files in `submission/evidence/`.
All were produced by the scripts in `submission/scripts/` against the live single-node K3s cluster.
Each appendix names the source file so any claim can be traced to its raw output.

Re-running everything from nothing:

```bash
bash scripts/deploy-all.sh          # build, deploy, wait for readiness
bash scripts/30-smoke-test.sh       # Appendix A
bash scripts/50-test-degradation.sh # Appendix B
bash scripts/55-test-ratelimit.sh   # Appendix C1
bash scripts/56-test-readiness-gate.sh
bash scripts/57-test-rollout-failure-recovery.sh
bash scripts/58-test-misconfig-diagnosis.sh
bash scripts/59-test-scaling.sh
bash scripts/60-test-networkpolicy.sh
bash scripts/70-test-persistence.sh
bash scripts/80-security-audit.sh
bash scripts/81-trivy-v1-vs-v2.sh
bash scripts/95-rebuild-from-scratch.sh
```

---

## Appendix A — Platform state and the main request path

Source: `cluster-state-*.log`, `smoke-test-*.log`

Cluster: K3s v1.36.3+k3s1 on Ubuntu 24.04.4 LTS, single node, 2 vCPU / 7.8 GB.
Namespace `shop` with `pod-security.kubernetes.io/enforce: restricted`.

Deployed objects: 5 Deployments (gateway ×2, checkout-fn ×2, pricing-fn ×2, inventory-fn ×2,
postgres ×1), 5 ClusterIP Services, 1 Ingress, 2 ConfigMaps, 1 Secret, 1 PVC, 5 ServiceAccounts,
12 NetworkPolicies, 1 Traefik Middleware.

A successful checkout, showing the composed result:

```json
{"status":"confirmed","degraded":false,
 "pricing":{"subtotal":100,"taxRate":0.23,"tax":23,"total":123},
 "stock":{"sku":1,"inStock":true,"confirmed":true},
 "requestId":"..."}
```

**Request correlation across three services.** One request ID appears in all three service logs,
which is what makes a distributed request diagnosable. Taken verbatim from
`smoke-test-20260814-161057.log`:

```
checkout-fn   request_id=smoke-1786723857 dependency=inventory status=200 duration_ms=98.1
checkout-fn   request_id=smoke-1786723857 dependency=pricing   status=200 duration_ms=299.3
checkout-fn   request_id=smoke-1786723857 route=/checkout      status=200 duration_ms=301.8
pricing-fn    request_id=smoke-1786723857 route=/price         status=200 duration_ms=0.6
inventory-fn  request_id=smoke-1786723857 route=/stock/1       status=200 duration_ms=3.3
```

These are first-request timings taken immediately after a full rebuild, so they include Node.js
process warm-up and the initial database connection: `checkout-fn` records 299.3 ms for the pricing
call while `pricing-fn` records 0.6 ms of actual work. That gap is the cost of a cold start, not of
the dependency, and it disappears on subsequent requests — the steady-state figures used in
Section 3 are 6–13 ms. The discrepancy is left visible here because it is exactly what per-hop
timings are for: without them the delay would have been misattributed to `pricing-fn`.

Input validation is enforced at the edge of the service: a negative subtotal returns HTTP 400
rather than being priced.

---

## Appendix B — Degradation under dependency failure

Source: `degradation-*.log`

| Stage | Condition | Result | Latency |
|---|---|---|---|
| B1 | healthy | HTTP 200, `degraded:false` | 10 ms |
| B2 | `inventory-fn` scaled to 0 | HTTP 200, `status:accepted_pending_stock_confirmation` | 1502 ms |
| B3 | `inventory-fn` restored | HTTP 200, `degraded:false` | 13 ms |
| B4 | `pricing-fn` delayed 3000 ms | HTTP 503 | 1504 ms |
| B5 | delay removed | HTTP 200 | 45 ms |

Latencies in B2 and B4 are the service-side `duration_ms`; the corresponding end-to-end times
measured at `curl` were 1504.6 ms and 1510.1 ms. Both sit on the 1500 ms timeout budget, which is
the intended behaviour: a failing dependency costs the budget and no more.

The asymmetry between B2 and B4 is the dependency classification working — inventory is
non-critical and degrades, pricing is critical and fails closed.

---

## Appendix C — Operational behaviour experiments

### C1 — Edge admission control

Source: `ratelimit-*.log`. 30 concurrent requests, with and without the Traefik middleware
(`average: 5, burst: 10`).

| Condition | Admitted | Rejected | p95 of admitted |
|---|---:|---:|---:|
| No rate limit | 30 | 0 | 0.168 s |
| Rate limited | 11 | 19 × HTTP 429 | 0.075 s |

### C2 — Rolling update, controlled A/B

Source: `rolling-update-ab-*.log`. Continuous requests during a gateway image change.

| Group | Configuration | Requests | Failures | Rate |
|---|---|---:|---:|---:|
| A (control) | no `preStop`, 1 s grace | 179 | 6 | 3.4% |
| B (fix) | `preStop` 5 s, 30 s grace | 208 | 3 | 1.4% |

Failures were recorded as HTTP 502 or as `000`, the latter meaning `curl` could not complete the
transfer. `000` is not asserted to be a timeout specifically.

`rolling-update-gateway-*.log` is an earlier single run of the same change that returned 204/204
successes. It is retained deliberately: it is the run that would have supported a stronger claim
than the evidence justifies, and the A/B experiment is what showed it to be unrepresentative.

### C3 — Bad readiness probe: Running but not Ready

Source: `readiness-gate-*.log`. The readiness path was pointed at `/definitely-not-a-real-path`.

```
pricing-fn-58d5cf59d6-phdmf   10.42.0.86   false   Running
pricing-fn-84ddfd689b-c4592   10.42.0.67   true    Running
pricing-fn-84ddfd689b-dgzdk   10.42.0.72   true    Running

not-Ready pod IP : 10.42.0.86
endpoint IPs     : [10.42.0.67 10.42.0.72]
Readiness probe failed: HTTP probe failed with statuscode: 404
```

The not-Ready pod's IP is absent from the Service endpoints, the rollout stalls at "1 out of 2
new replicas have been updated", and 10/10 checkouts still return 200.

### C4 — Bad image tag and rollback

Source: `rollout-failure-recovery-*.log`.

```
checkout-fn-699f66c9db-ckmp9   0/1   ErrImagePull
rs checkout-fn-5949488f54  DESIRED=2  CURRENT=2  READY=2
rs checkout-fn-699f66c9db  DESIRED=1  CURRENT=1  READY=0
rollout status exit code: 124
```

15/15 checkouts returned 200 throughout. `kubectl rollout undo` restored the previous revision in
under one second.

### C5 — Configuration error diagnosis (Lab 4.2, required exercise)

Source: `misconfig-diagnosis-*.log`. The gateway upstream was changed to the Compose service name.

```
nginx: [emerg] host not found in upstream "checkout-fn" in /etc/nginx/conf.d/default.conf:17
gateway-897ddbfc7-x985t    0/1   CrashLoopBackOff
```

Diagnosis path: gateway pods → no Service named `checkout-fn` → the real Service `checkout-svc`
has healthy endpoints → the gateway's own log names the cause. The backend was never unhealthy.

The lab predicts HTTP 503. This platform returned 200 throughout, because the broken pod never
passed readiness and the previous replicas kept serving. The script asserts that the injection
actually took effect before reporting, after a first run silently failed to inject and produced a
misleading "healthy" log.

### C6 — Manual scaling

Source: `scaling-*.log`. `checkout-fn` scaled 2 → 10 → 2; 14/14 requests returned 200 throughout,
10 replicas Ready in 10 s, no Pending pods. Node reservation at 10 replicas: CPU requests 55%,
CPU limits 254% — the limits are oversubscribed, which is acceptable only because these services
are latency-bound rather than CPU-bound.

---

## Appendix D — Trust boundary enforcement

Source: `networkpolicy-*.log`. 19 cases, all passing.

| Group | Cases | Expectation |
|---|---|---|
| A. Documented paths | gateway→checkout, checkout→pricing, checkout→inventory, inventory→postgres | ALLOWED |
| B. Lateral movement | gateway→pricing, gateway→inventory, gateway→postgres, pricing→inventory, pricing→postgres, checkout→postgres | BLOCKED |
| C. Compromised workload (unlabelled pod) | →checkout, →pricing, →inventory, →postgres | BLOCKED |
| D. Egress | checkout→internet, pricing→internet, inventory→internet, gateway→internet, inventory→169.254.169.254 | BLOCKED |

D5 is the cloud metadata endpoint, reachable from the workload holding database credentials if
egress were unrestricted. DNS is the single deliberate egress exception.

---

## Appendix E — Rebuild from nothing

Source: `rebuild-from-scratch-*.log`

```
teardown (namespace delete)          real 1m0.747s
rebuild (deploy-all.sh)              real 0m30.042s
verify main path                     HTTP 200
networkpolicies after rebuild        12
```

The PVC is deleted with the namespace, so seeded stock data is recreated by `inventory-fn` on
startup. This is the data-lifecycle coupling discussed in Section 5, and it is visible here rather
than hidden.

---

## Appendix F — Security posture

Source: `security-audit-*.log`, `trivy-v1-vs-v2-*.log`, `kubesec-all-workloads-*.log`

**kubesec** (raw score, higher is better; every Deployment read from the live cluster by
`83-kubesec-all-and-metrics.sh`, so these describe what is actually running):

| Deployment | Score | Rules not satisfied |
|---|---:|---|
| `checkout-fn` | 12 | ApparmorAny, SeccompAny, RunAsGroup, RunAsUser |
| `gateway` | 12 | ApparmorAny, SeccompAny, RunAsGroup, RunAsUser |
| `inventory-fn` | 12 | ApparmorAny, SeccompAny, RunAsGroup, RunAsUser |
| `pricing-fn` | 12 | ApparmorAny, SeccompAny, RunAsGroup, RunAsUser |
| `postgres` | 11 | the same four, plus `ReadOnlyRootFilesystem` |

The one-point gap for Postgres is not an oversight in the scan: `readOnlyRootFilesystem` is set
`false` in `20-postgres.yaml`, so kubesec lists that rule under *advise* for Postgres and under
*passed* for the four application workloads. The earlier `80-security-audit.sh` run scored only
two workloads because piping a multi-document manifest to `kubesec scan /dev/stdin` reads the
first document alone; script `83` was written to close that gap.

**Trivy**, same scan against both image generations (`81-trivy-v1-vs-v2.sh`):

| Image | CRITICAL | HIGH |
|---|---:|---:|
| `ead/pricing-fn:v1` | 1 | 6 |
| `ead/inventory-fn:v1` | 1 | 6 |
| `ead/checkout-fn:v1` | 1 | 6 |
| `ead/pricing-fn:v2` | 0 | 0 |
| `ead/inventory-fn:v2` | 0 | 0 |
| `ead/checkout-fn:v2` | 0 | 0 |

The cluster runs the `v2` images. `82-trivy-v1-detail.sh` retains the finding-level detail behind
the interpretation (`trivy-v1-detail-*.log`): `Total: 7 (HIGH: 6, CRITICAL: 1)`, the CRITICAL being
`CVE-2026-59873` in `tar` (node-tar, gzip-bomb denial of service), alongside `brace-expansion`,
`ip-address` and `undici` findings. The same script inspects both images directly:

```
npm CLI present in v1
npm CLI absent in v2
```

That is the evidence for the claim that the findings came from the bundled package manager rather
than from anything the service loads at runtime, and that removing it is a real fix rather than a
suppression.

**Workload identity:** 9/9 pods run under a dedicated ServiceAccount; none uses `default`; token
automounting is disabled everywhere.

**Repository credential scan:** PASS — no literal credentials in manifests or source. The
credential is generated at deploy time by `20-create-secret.sh`; the repository holds only
`11-secret.example.yaml` with a placeholder.

**Disclosed residual risk:** the audit reports that `PGPASSWORD` is retrievable as base64 by any
principal holding `get secret`, and that K3s stores Secrets unencrypted at rest by default. The
audit script reports the credential's length only and never its value.

---

## Appendix G — Data lifecycle

Source: `persistence-*.log`. A marker row was written, the PostgreSQL pod deleted, and the marker
read back from the replacement pod:

```
looked for: marker-1786723909
found     : marker-1786723909
RESULT: PASS - data survived pod replacement
```
