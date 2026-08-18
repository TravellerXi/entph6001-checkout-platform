#!/usr/bin/env bash
# Controlled A/B experiment for the rolling-update defect.
#
# Group A (control): no preStop hook, 1s grace period  -> reproduces the original 502
# Group B (fix):     preStop sleep 5, 30s grace period -> expected zero 5xx
#
# Restores the fixed configuration on exit regardless of outcome.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/rolling-update-ab-$(date +%Y%m%d-%H%M%S).log"
ROOT="$HOME/ead"

load_during_restart() {
  local label="$1" duration=40
  ( end=$(( $(date +%s) + duration ))
    while [ "$(date +%s)" -lt "$end" ]; do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
        -X POST http://localhost/api/checkout \
        -H 'content-type: application/json' \
        --data '{"sku":1,"subtotal":100}' 2>/dev/null || echo "000"
      sleep 0.15
    done ) > "/tmp/codes-${label}.txt" &
  local pid=$!
  sleep 4
  kubectl -n shop rollout restart deployment/gateway >/dev/null
  kubectl -n shop rollout status deployment/gateway --timeout=120s >/dev/null
  wait $pid
  echo "--- ${label} status distribution"
  sort "/tmp/codes-${label}.txt" | uniq -c | sort -rn
  local total bad
  total=$(wc -l < "/tmp/codes-${label}.txt")
  bad=$(grep -cE '^(5[0-9]{2}|000)$' "/tmp/codes-${label}.txt" || true)
  echo "--- ${label}: total=${total} failures=${bad}"
}

restore_fixed() {
  kubectl apply -f "${ROOT}/k8s/40-gateway.yaml" >/dev/null 2>&1
  kubectl -n shop rollout status deployment/gateway --timeout=120s >/dev/null 2>&1
  echo "(fixed configuration restored)"
}
trap restore_fixed EXIT

{
echo "======== GROUP A (control): preStop removed, grace period 1s"
kubectl -n shop patch deployment gateway --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"},
       {"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":1}]' >/dev/null
kubectl -n shop rollout status deployment/gateway --timeout=120s >/dev/null
echo "config: $(kubectl -n shop get deploy gateway -o jsonpath='{.spec.template.spec.containers[0].lifecycle}{" grace="}{.spec.template.spec.terminationGracePeriodSeconds}')"
load_during_restart "control"

echo
echo "======== GROUP B (fix): preStop sleep 5, grace period 30s"
kubectl apply -f "${ROOT}/k8s/40-gateway.yaml" >/dev/null
kubectl -n shop rollout status deployment/gateway --timeout=120s >/dev/null
echo "config: $(kubectl -n shop get deploy gateway -o jsonpath='{.spec.template.spec.containers[0].lifecycle}{" grace="}{.spec.template.spec.terminationGracePeriodSeconds}')"
load_during_restart "fix"
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
