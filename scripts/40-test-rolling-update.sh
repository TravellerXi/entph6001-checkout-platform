#!/usr/bin/env bash
# Operational behaviour experiment A: availability during a rolling update.
# Drives continuous traffic through the Ingress while a Deployment is restarted, and reports
# the status-code distribution. A correct configuration should show zero 5xx.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

TARGET="${1:-gateway}"
DURATION="${DURATION:-45}"
OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${OUT}/rolling-update-${TARGET}-${STAMP}.log"

echo "== rolling-update availability test: deployment/${TARGET}, ${DURATION}s" | tee "$LOG"

(
  end=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$end" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -X POST http://localhost/api/checkout \
      -H 'content-type: application/json' \
      --data '{"sku":1,"subtotal":100}' || echo "000")
    echo "$code"
    sleep 0.2
  done
) > /tmp/codes.txt &
LOADPID=$!

sleep 5
echo "-- triggering rollout restart" | tee -a "$LOG"
kubectl -n shop rollout restart "deployment/${TARGET}" >>"$LOG" 2>&1
kubectl -n shop rollout status "deployment/${TARGET}" --timeout=120s | tee -a "$LOG"

wait $LOADPID

echo "-- status code distribution" | tee -a "$LOG"
sort /tmp/codes.txt | uniq -c | sort -rn | tee -a "$LOG"

TOTAL=$(wc -l < /tmp/codes.txt)
BAD=$(grep -cE '^(5[0-9]{2}|000)$' /tmp/codes.txt || true)
echo "-- total=${TOTAL} failures(5xx/timeout)=${BAD}" | tee -a "$LOG"
echo "evidence: ${LOG}"
