#!/usr/bin/env bash
# Operational behaviour experiment C: edge admission control (Lab 11 §11.4).
#
# Sends a burst well above the configured average, with and without the rate-limit middleware,
# and compares the outcome. The point is not that requests are rejected — it is that rejection is
# cheap, early, and protects the latency of admitted requests.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/ratelimit-$(date +%Y%m%d-%H%M%S).log"
ROOT="$HOME/ead"
BURST="${BURST:-30}"

burst_test() {
  local label="$1"
  rm -f /tmp/rl-codes.txt /tmp/rl-times.txt
  for _ in $(seq 1 "$BURST"); do
    curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 10 \
      -X POST http://localhost/api/checkout \
      -H 'content-type: application/json' \
      --data '{"sku":1,"subtotal":100}' >> /tmp/rl-codes.txt 2>/dev/null &
  done
  wait
  echo "--- ${label}: ${BURST} concurrent requests"
  awk '{print $1}' /tmp/rl-codes.txt | sort | uniq -c | sort -rn | sed 's/^/    /'
  local admitted p95
  admitted=$(grep -c '^200' /tmp/rl-codes.txt || true)
  p95=$(grep '^200' /tmp/rl-codes.txt | awk '{print $2}' | sort -n | awk '{a[NR]=$1} END{if(NR>0) printf "%.3f", a[int(NR*0.95)==0?1:int(NR*0.95)]}')
  echo "    admitted=${admitted}  p95_latency_of_admitted=${p95:-n/a}s"
}

{
echo "======== A. WITHOUT rate limiting"
kubectl -n shop annotate ingress shop-ingress traefik.ingress.kubernetes.io/router.middlewares- --overwrite >/dev/null 2>&1
sleep 3
burst_test "no rate limit"

echo
echo "======== B. WITH rate limiting (average=5, burst=10)"
kubectl apply -f "${ROOT}/k8s/41-ratelimit-middleware.yaml" >/dev/null
kubectl apply -f "${ROOT}/k8s/40-gateway.yaml" >/dev/null
sleep 3
kubectl -n shop get middleware checkout-ratelimit -o jsonpath='{.spec.rateLimit}'; echo
burst_test "rate limited"

echo
echo "======== Interpretation"
echo "429 responses are the admission control working: excess load is refused at the edge"
echo "instead of being queued through the gateway into checkout, pricing and the database."
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
