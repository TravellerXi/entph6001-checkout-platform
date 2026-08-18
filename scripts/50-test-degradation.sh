#!/usr/bin/env bash
# Operational behaviour experiment B: partial failure, graceful degradation, and recovery.
#
# The architecture claims inventory is a NON-critical dependency (degrade) while pricing is
# CRITICAL (fail fast). This script tests both claims and captures the evidence.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/degradation-$(date +%Y%m%d-%H%M%S).log"

call() {
  local rid="$1"
  curl -s -w '\nHTTP %{http_code}  total=%{time_total}s\n' --max-time 10 \
    -X POST http://localhost/api/checkout \
    -H 'content-type: application/json' \
    -H "x-request-id: ${rid}" \
    --data '{"sku":1,"subtotal":100}'
}

wait_ready() {
  kubectl -n shop rollout status "deployment/$1" --timeout=120s >/dev/null
}

{
echo "================ PHASE 1: baseline (all dependencies healthy)"
call "deg-baseline"

echo
echo "================ PHASE 2: inventory-fn scaled to zero (non-critical dependency lost)"
kubectl -n shop scale deployment/inventory-fn --replicas=0 >/dev/null
kubectl -n shop wait --for=delete pod -l app=inventory-fn --timeout=60s >/dev/null 2>&1 || sleep 5
echo "-- endpoints for inventory-svc:"
kubectl -n shop get endpoints inventory-svc -o jsonpath='{.subsets}'; echo " (empty means no backends)"
echo "-- checkout request with inventory down:"
call "deg-inventory-down"

echo
echo "================ PHASE 3: inventory-fn restored"
kubectl -n shop scale deployment/inventory-fn --replicas=2 >/dev/null
wait_ready inventory-fn
call "deg-inventory-restored"

echo
echo "================ PHASE 4: pricing-fn made slow (3000ms > TIMEOUT_MS 1500ms)"
kubectl -n shop set env deployment/pricing-fn DELAY_MS=3000 >/dev/null
wait_ready pricing-fn
echo "-- checkout request with pricing exceeding the timeout budget:"
call "deg-pricing-slow"

echo
echo "================ PHASE 5: pricing-fn latency removed"
kubectl -n shop set env deployment/pricing-fn DELAY_MS=0 >/dev/null
wait_ready pricing-fn
call "deg-recovered"

echo
echo "================ Correlated log evidence (checkout-fn)"
for rid in deg-baseline deg-inventory-down deg-pricing-slow deg-recovered; do
  echo "--- ${rid}"
  kubectl -n shop logs -l app=checkout-fn --tail=500 2>/dev/null | grep -F "\"${rid}\"" || echo "    (no match)"
done

echo
echo "================ Degradation counters"
# An earlier run left this section empty because the pod list came back blank and the loop body
# simply never executed. Capture the list first so an empty result is reported rather than hidden.
pods=$(kubectl -n shop get pods -l app=checkout-fn -o name 2>/dev/null)
if [ -z "$pods" ]; then
  echo "    (no checkout-fn pods found)"
else
  for pod in $pods; do
    echo "--- ${pod}"
    kubectl -n shop exec "${pod}" -- wget -qO- http://localhost:3003/metrics 2>/dev/null \
      || echo "    (metrics unavailable)"
  done
fi
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
