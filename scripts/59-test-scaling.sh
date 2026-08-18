#!/usr/bin/env bash
# Lab 3.4 Part 1 — manual horizontal scaling, and what it costs on a single node.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/scaling-$(date +%Y%m%d-%H%M%S).log"

hit() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST http://localhost/api/checkout \
        -H 'content-type: application/json' --data '{"sku":1,"subtotal":100}'; }

{
echo "--- 1. Starting state"
kubectl -n shop get deployment checkout-fn --no-headers | awk '{print "    checkout-fn READY="$2"  AVAILABLE="$4}'
echo "    node allocatable: $(kubectl get node -o jsonpath='{.items[0].status.allocatable.cpu}') CPU, $(kubectl get node -o jsonpath='{.items[0].status.allocatable.memory}') memory"

echo
echo "--- 2. Scale out 2 -> 10, sampling availability throughout (paced under the rate limit)"
t0=$(date +%s)
kubectl -n shop scale deployment/checkout-fn --replicas=10 >/dev/null
codes=""
for _ in $(seq 1 14); do codes="${codes}$(hit) "; sleep 0.3; done
kubectl -n shop rollout status deployment/checkout-fn --timeout=120s >/dev/null 2>&1
t1=$(date +%s)
echo "    responses during scale-out: ${codes}"
echo "    reached 10 replicas in $((t1-t0))s"
kubectl -n shop get deployment checkout-fn --no-headers | awk '{print "    READY="$2"  UP-TO-DATE="$3"  AVAILABLE="$4}'
pend=$(kubectl -n shop get pods -l app=checkout-fn --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
echo "    Pending pods: ${pend}"

echo
echo "--- 3. What the scheduler had to reserve"
kubectl describe node 2>/dev/null | sed -n '/Allocated resources/,/^Events/p' | grep -E 'cpu|memory|Resource' | head -4 | sed 's/^/    /'
echo "    NOTE: replicas are bounded by one node's allocatable capacity. Horizontal scaling here"
echo "    buys concurrency and rollout safety, not fault tolerance: all 10 replicas share the"
echo "    single node, so this does not address the single point of failure."

echo
echo "--- 4. Scale back 10 -> 2"
kubectl -n shop scale deployment/checkout-fn --replicas=2 >/dev/null
sleep 12
kubectl -n shop get deployment checkout-fn --no-headers | awk '{print "    READY="$2"  AVAILABLE="$4}'
echo "    checkout -> HTTP $(hit)"
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
