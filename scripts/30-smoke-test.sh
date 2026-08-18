#!/usr/bin/env bash
# End-to-end smoke test of the main request path, exercised through the Ingress.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

BASE="${BASE:-http://localhost}"
RID="smoke-$(date +%s)"

echo "=== 1. Ingress -> gateway -> checkout -> pricing + inventory -> postgres"
curl -s -o /tmp/smoke-body.json -w 'HTTP %{http_code}  total=%{time_total}s\n' \
  -X POST "${BASE}/api/checkout" \
  -H 'content-type: application/json' \
  -H "x-request-id: ${RID}" \
  --data '{"sku":1,"subtotal":100}'
echo "--- response body ---"
cat /tmp/smoke-body.json; echo

echo
echo "=== 2. Out-of-stock SKU (sku=3 seeded as false)"
curl -s -X POST "${BASE}/api/checkout" \
  -H 'content-type: application/json' \
  --data '{"sku":3,"subtotal":50}'; echo

echo
echo "=== 3. Input validation (negative subtotal must be rejected)"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST "${BASE}/api/checkout" \
  -H 'content-type: application/json' \
  --data '{"sku":1,"subtotal":-5}'

echo
echo "=== 4. Request-ID propagation across all three services"
for app in checkout-fn pricing-fn inventory-fn; do
  echo "--- ${app}"
  kubectl -n shop logs -l "app=${app}" --tail=200 2>/dev/null | grep -F "${RID}" || echo "    (no match)"
done
