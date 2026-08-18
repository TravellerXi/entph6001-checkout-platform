#!/usr/bin/env bash
# Lab 3.4 Part 2 + Lab 4.3 Ex2: a bad release must be stopped by the platform, not by the users.
#
# Deploys a deliberately broken image tag, shows the rollout stalls while the old pods keep
# serving 100% of traffic, reads the diagnosis out of the events, then rolls back.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/rollout-failure-recovery-$(date +%Y%m%d-%H%M%S).log"

hit() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST http://localhost/api/checkout \
        -H 'content-type: application/json' --data '{"sku":1,"subtotal":100}'; }

{
echo "--- 1. Healthy baseline"
kubectl -n shop get deployment checkout-fn --no-headers | awk '{print "    READY="$2"  AVAILABLE="$4}'
kubectl -n shop rollout history deployment/checkout-fn | sed 's/^/    /'

echo
echo "--- 2. Deploy a broken image tag"
kubectl -n shop set image deployment/checkout-fn checkout-fn=ead/checkout-fn:broken-tag >/dev/null
echo "    rollout status (bounded wait, expected to NOT complete):"
timeout 60 kubectl -n shop rollout status deployment/checkout-fn 2>&1 | tail -2 | sed 's/^/      /'
echo "    exit code from rollout status: $?  (non-zero = the platform refused to finish the release)"

echo
echo "--- 3. Availability DURING the failed rollout"
echo "    (paced at ~3 req/s to stay under the edge rate limit of average=5, so that any"
echo "     non-200 here is attributable to the rollout and not to admission control)"
codes=""
for _ in $(seq 1 15); do codes="${codes}$(hit) "; sleep 0.3; done
ok=$(echo "$codes" | tr ' ' '\n' | grep -c '^200$')
rl=$(echo "$codes" | tr ' ' '\n' | grep -c '^429$')
echo "    responses: ${codes}"
echo "    200=${ok}/15   429(rate-limited)=${rl}   other=$((15-ok-rl))"
echo "    <-- old ReplicaSet still serving; users never saw the bad build"

echo
echo "--- 4. Diagnosis from the cluster, not from guesswork"
kubectl -n shop get pods -l app=checkout-fn --no-headers | sed 's/^/    /'
echo "    pod events:"
kubectl -n shop describe pod -l app=checkout-fn 2>/dev/null | grep -E 'Failed|ErrImage|ImagePull|Back-off' | head -4 | sed 's/^/      /'
echo "    replicaset view (new RS cannot become available):"
kubectl -n shop get rs -l app=checkout-fn --no-headers | awk '{print "      "$1"  DESIRED="$2"  CURRENT="$3"  READY="$4}'

echo
echo "--- 5. Roll back"
t0=$(date +%s)
kubectl -n shop rollout undo deployment/checkout-fn >/dev/null
kubectl -n shop rollout status deployment/checkout-fn --timeout=120s 2>&1 | tail -1 | sed 's/^/    /'
t1=$(date +%s)
echo "    rollback completed in $((t1-t0))s"
kubectl -n shop get deployment checkout-fn --no-headers | awk '{print "    READY="$2"  AVAILABLE="$4}'
echo "    image now: $(kubectl -n shop get deployment checkout-fn -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "    checkout -> HTTP $(hit)"
kubectl -n shop rollout history deployment/checkout-fn | sed 's/^/    /'
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
