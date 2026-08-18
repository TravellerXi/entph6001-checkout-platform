# Screencast script — 8 minutes maximum

Recorded by the author with voice-over. Timings are targets; the hard limit is 8:00.
Every command below is real and has been executed — no simulated output.

**Setup before recording:** two terminals side by side, both SSH'd to the cluster host.
Terminal A for commands, Terminal B tailing logs. Browser tab on the tunnelled gateway.

---

## 0:00–0:40 — What the assignment asked and what was built

> "The organisation runs a checkout application as a small set of containers. I've re-architected it
> as a cloud-native platform on K3s with three trust tiers. What I want to show you is not that it
> deploys, but that its architectural claims are testable — and that I tested them."

Show `docs/diagram-1-architecture.md` rendered. Point at the three tiers.

## 0:40–1:40 — The platform is real

```bash
kubectl get nodes -o wide
kubectl -n shop get pods -L tier
kubectl -n shop get svc,ingress,pvc
```

> "Nine pods across three tiers. Two replicas of each stateless service, one PostgreSQL with a
> persistent volume. One Ingress — that is the only way in."

## 1:40–2:40 — The main request path, end to end

```bash
bash scripts/30-smoke-test.sh
```

> "One checkout goes through Ingress, gateway, checkout, then fans out to pricing and inventory in
> parallel, and inventory reads PostgreSQL. Note the same request ID appears in all three services —
> that is what makes a distributed failure diagnosable."

Point at the correlated log lines for the same `request_id`.

## 2:40–4:10 — Operational behaviour: degradation versus fail-fast

```bash
bash scripts/50-test-degradation.sh
```

Narrate each phase as it prints:

> "Baseline, about ten milliseconds. Now I remove inventory entirely — this is a *non-critical*
> dependency, so checkout degrades: HTTP 200, order accepted, stock unconfirmed. Read the latency
> off the screen rather than from me: on 14 August this took 1502 milliseconds because the call
> hung until the budget expired, and on 18 August it took about 8 milliseconds because a Service
> with no endpoints refused the connection outright. Both are in the evidence, and the point is
> that 1500 milliseconds is the *ceiling* on what a dead dependency can cost, not a fixed price.
> Restore it, back to normal.
> Now I make pricing slow — 3000 milliseconds against a 1500 millisecond budget. Pricing is
> *critical*: no total means no order, so it fails fast with 503 at 1504 milliseconds rather than
> hanging the customer.
> The cost is honest: when the budget binds, degradation turns an 11 ms response into 1.5 seconds.
> But it is a bound, not a fixed price — in the repeat run you can see on screen the same test
> degrades in about 8 milliseconds, because a Service with no endpoints refuses the connection
> instead of hanging. A circuit breaker is the
> right next step, and I say so in the report."

## 4:10–5:10 — A real defect, found, fixed, and honestly measured

> "During development the smoke test intermittently returned 502, and the control group in the
> experiment below reproduces it. The standard remedy is a preStop delay plus a grace period, so
> that the endpoints controller removes the pod before it stops accepting connections; I applied
> that and measured whether it helped."

```bash
tail -20 evidence/rolling-update-ab-*.log
```

> "A single clean run would have proved nothing about an intermittent fault, so I ran it as a
> controlled A/B. The control group failed 6 of 179 requests, 3.4 percent. With the fix, 3 of 208,
> 1.4 percent. I want to be careful about that number: with these sample sizes the difference is not
> statistically significant, and the control also ran with a 1-second grace period against the
> 30-second platform default, so two variables moved together. What I can say is that it did not
> eliminate the failures, and that an earlier single run returning 204 out of 204 was simply
> unrepresentative."

## 5:10–6:20 — Security validation: are the trust tiers real?

```bash
bash scripts/60-test-networkpolicy.sh
```

> "Four documented paths must work. Six lateral paths must fail. Five outbound paths must fail,
> including the cloud metadata endpoint. And an unlabelled pod — simulating a compromised workload
> — must reach nothing at all. Nineteen out of nineteen.
> This matters because NetworkPolicy objects are silently inert on a cluster without a policy-capable
> CNI. The negative controls are what prove enforcement rather than intent."

## 6:20–7:20 — Security validation: configuration and images

Show the relevant section of `evidence/kubesec-all-workloads-*.log` and `evidence/trivy-v1-vs-v2-*.log`.

> "kubesec scores every Deployment, read straight from the running cluster. The four application
> workloads score 12 — non-root, capabilities dropped, read-only root filesystem,
> resource limits, a dedicated ServiceAccount per workload, no token mounting. Postgres scores 11,
> and the missing point is exactly one rule: its root filesystem is writable. Trivy flagged one
> CRITICAL and six HIGH per image, including CVE-2026-59873 in node-tar. All of them came from the
> npm CLI bundled in the base image, not from anything the service loads at runtime. So instead of
> suppressing them I rebuilt the images multi-stage without the package manager. Same scan against
> the rebuilt images: zero critical, zero high — and the cluster runs those rebuilt images.
> The highest remaining risk is that Kubernetes Secrets are base64 only and encryption at rest is off
> — I demonstrate that without printing the value."

## 7:20–8:00 — Reproducibility and honest limitations

```bash
tail -20 evidence/rebuild-from-scratch-*.log
```

> "I deleted the entire namespace and rebuilt from the manifests in one command: teardown 61
> seconds, then 30 seconds to a working checkout.
> What's missing: one node and one database replica, so no real availability story; no backups; and
> the trust model is network-based, not identity-based — a compromised checkout is indistinguishable
> from a real one. mTLS with workload identity is the next increment I'd fund."
