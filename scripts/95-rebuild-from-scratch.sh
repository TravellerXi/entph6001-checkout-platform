#!/usr/bin/env bash
# Reproducibility proof: destroy the namespace entirely, then rebuild from the manifests alone.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/rebuild-from-scratch-$(date +%Y%m%d-%H%M%S).log"
ROOT="$HOME/ead"

{
echo "==== BEFORE: existing state"
kubectl -n shop get pods --no-headers 2>/dev/null | wc -l | sed 's/^/pods: /'
kubectl get ns shop -o jsonpath='{.status.phase}' 2>/dev/null | sed 's/^/namespace: /'; echo

echo
echo "==== DESTROY: delete the entire namespace (workloads, config, secret, PVC)"
time kubectl delete namespace shop --timeout=300s
echo "namespace gone: $(kubectl get ns shop 2>&1 | grep -c NotFound)"

echo
echo "==== REBUILD: single command, from manifests only"
time bash "${ROOT}/scripts/deploy-all.sh"

echo
echo "==== VERIFY: main request path works on the rebuilt platform"
sleep 5
curl -s -w '\nHTTP %{http_code}\n' -X POST http://localhost/api/checkout \
  -H 'content-type: application/json' -H 'x-request-id: rebuild-verify' \
  --data '{"sku":1,"subtotal":100}'

echo
echo "==== VERIFY: trust boundaries re-established"
kubectl -n shop get networkpolicy --no-headers | wc -l | sed 's/^/networkpolicies: /'
echo
echo "==== NOTE: the PVC was deleted with the namespace, so seeded stock data is"
echo "     recreated by inventory-fn on startup. This is intentional for a lab rebuild;"
echo "     a production design would keep the volume outside the application namespace lifecycle."
} > "$LOG" 2>&1

echo "REBUILD_COMPLETE"
tail -30 "$LOG"
