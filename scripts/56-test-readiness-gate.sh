#!/usr/bin/env bash
# Lab 3.7 Ex2 — Ready vs Running.
#
# Breaking only the readiness probe produces three separate, observable effects:
#   1. the pod is Running (the process is fine) but not Ready,
#   2. its IP is withheld from the Service endpoints, so it receives no traffic,
#   3. the rolling update refuses to finish, so the previous pods keep serving users.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/readiness-gate-$(date +%Y%m%d-%H%M%S).log"

hit() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST http://localhost/api/checkout \
        -H 'content-type: application/json' --data '{"sku":1,"subtotal":100}'; }
eps() { kubectl -n shop get endpoints pricing-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null; }
pods() { kubectl -n shop get pods -l app=pricing-fn -o custom-columns='NAME:.metadata.name,IP:.status.podIP,READY:.status.containerStatuses[0].ready,PHASE:.status.phase' --no-headers; }

restore() {
  kubectl -n shop patch deployment pricing-fn --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health"}]' >/dev/null 2>&1
  kubectl -n shop rollout status deployment/pricing-fn --timeout=120s >/dev/null 2>&1
}
trap restore EXIT

{
echo "--- 1. Baseline: every pod Ready, every pod IP present in the Service"
pods | sed 's/^/    /'
echo "    pricing-svc endpoints: [$(eps)]"
echo "    checkout -> HTTP $(hit)"
echo "    rollout strategy: $(kubectl -n shop get deployment pricing-fn -o jsonpath='{.spec.strategy.rollingUpdate}')"

echo
echo "--- 2. Break ONLY the readiness probe path (liveness and the process are untouched)"
kubectl -n shop patch deployment pricing-fn --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/definitely-not-a-real-path"}]' >/dev/null
echo "    waiting for the new pod to settle..."
sleep 40

echo
echo "--- 3. Observation A: Running but not Ready"
pods | sed 's/^/    /'

BADIP=$(kubectl -n shop get pods -l app=pricing-fn -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{.status.podIP}{"\n"}{end}' | awk '$1=="false"{print $2}' | head -1)
EPLIST="$(eps)"
echo
echo "--- 4. Observation B: the not-Ready pod is withheld from the Service"
echo "    not-Ready pod IP : ${BADIP:-none}"
echo "    endpoint IPs     : [${EPLIST}]"
if [ -n "${BADIP}" ] && echo " ${EPLIST} " | grep -q " ${BADIP} "; then
  echo "    RESULT: FAIL — a not-Ready pod is receiving traffic"
else
  echo "    RESULT: PASS — the not-Ready pod IP is absent from the endpoint list, so kube-proxy"
  echo "            will never route a request to it. Readiness is a traffic gate, not a label."
fi
echo "    probe failure reported by the kubelet:"
kubectl -n shop get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp 2>/dev/null | tail -2 | sed 's/^/      /'

echo
echo "--- 5. Observation C: the bad release cannot complete, so users are unaffected"
echo "    rollout status (bounded wait):"
timeout 30 kubectl -n shop rollout status deployment/pricing-fn 2>&1 | tail -1 | sed 's/^/      /'
kubectl -n shop get deployment pricing-fn --no-headers | awk '{print "    deployment: READY="$2"  UP-TO-DATE="$3"  AVAILABLE="$4}'
codes=""; for _ in $(seq 1 10); do codes="${codes}$(hit) "; done
echo "    checkout x10 during the stalled rollout: ${codes}"

echo
echo "--- 6. Repair"
restore
pods | sed 's/^/    /'
echo "    pricing-svc endpoints: [$(eps)]"
echo "    checkout -> HTTP $(hit)"
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
