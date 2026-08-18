#!/usr/bin/env bash
# Persistence validation: data written before a pod restart must survive it (Lab 3.5 pattern).
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/persistence-$(date +%Y%m%d-%H%M%S).log"

psql_exec() {
  local pod
  pod=$(kubectl -n shop get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
  kubectl -n shop exec "$pod" -- psql -U shop -d shop -tAc "$1"
}

{
echo "== 1. PVC and volume binding"
kubectl -n shop get pvc postgres-pvc
echo
echo "== 2. Write a marker row"
MARKER="marker-$(date +%s)"
psql_exec "CREATE TABLE IF NOT EXISTS persistence_check (id SERIAL PRIMARY KEY, marker TEXT, created_at TIMESTAMPTZ DEFAULT now());"
psql_exec "INSERT INTO persistence_check (marker) VALUES ('${MARKER}');"
echo "   inserted: ${MARKER}"
echo "   rows now: $(psql_exec 'SELECT count(*) FROM persistence_check;')"

echo
echo "== 3. Baseline stock table (seeded by inventory-fn at startup)"
psql_exec "SELECT sku, in_stock FROM stock ORDER BY sku;"

echo
echo "== 4. Delete the postgres pod (simulating node/pod failure)"
OLD=$(kubectl -n shop get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
echo "   deleting ${OLD}"
kubectl -n shop delete pod "$OLD" --wait=true >/dev/null
kubectl -n shop rollout status deployment/postgres --timeout=180s
NEW=$(kubectl -n shop get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
echo "   new pod: ${NEW}"
[ "$OLD" != "$NEW" ] && echo "   confirmed: pod identity changed" || echo "   WARNING: same pod name"

echo
echo "== 5. Read the marker back after restart"
sleep 5
FOUND=$(psql_exec "SELECT marker FROM persistence_check WHERE marker='${MARKER}';" | tr -d '[:space:]')
echo "   looked for: ${MARKER}"
echo "   found     : ${FOUND:-<nothing>}"
if [ "$FOUND" = "$MARKER" ]; then
  echo "   RESULT: PASS - data survived pod replacement"
else
  echo "   RESULT: FAIL - data lost"
fi

echo
echo "== 6. Application-level recovery (inventory-fn reconnects, checkout works)"
kubectl -n shop wait --for=condition=available --timeout=120s deployment/inventory-fn >/dev/null
curl -s -w '\nHTTP %{http_code}\n' -X POST http://localhost/api/checkout \
  -H 'content-type: application/json' -H 'x-request-id: persistence-recheck' \
  --data '{"sku":1,"subtotal":100}'
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
