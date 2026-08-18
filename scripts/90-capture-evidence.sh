#!/usr/bin/env bash
# Captures the cluster-state evidence that the report appendices reference.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/cluster-state-$(date +%Y%m%d-%H%M%S).log"

{
echo "############ Cluster and platform"
kubectl get nodes -o wide
echo
kubectl version --output=yaml 2>/dev/null | grep -E 'gitVersion|platform' | head -4
echo
echo "############ Workloads"
kubectl -n shop get deploy,svc,ingress,pvc -o wide
echo
echo "############ Pods with images and trust tier"
kubectl -n shop get pods -L tier -o wide
echo
echo "############ Images actually running"
kubectl -n shop get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image' --no-headers | sort
echo
echo "############ Ingress routing"
kubectl -n shop describe ingress shop-ingress | sed -n '1,25p'
echo
echo "############ NetworkPolicies"
kubectl -n shop get networkpolicy
echo
echo "############ Configuration surface (non-secret)"
kubectl -n shop get configmap platform-config -o jsonpath='{.data}'; echo
echo
echo "############ Secret metadata only (values never printed)"
kubectl -n shop get secret db-credentials -o jsonpath='{.metadata.name}{"  type="}{.type}{"  keys="}'; \
  kubectl -n shop get secret db-credentials -o jsonpath='{.data}' | tr ',' '\n' | grep -o '"[A-Z_]*"' | tr '\n' ' '; echo
echo
echo "############ Probe configuration (liveness shallow vs readiness deep)"
kubectl -n shop get deploy -o custom-columns='DEPLOY:.metadata.name,READINESS:.spec.template.spec.containers[0].readinessProbe.httpGet.path,LIVENESS:.spec.template.spec.containers[0].livenessProbe.httpGet.path' --no-headers
echo
echo "############ Recent structured logs (one sample per service)"
for app in gateway checkout-fn pricing-fn inventory-fn; do
  echo "--- ${app}"
  kubectl -n shop logs -l "app=${app}" --tail=3 2>/dev/null | tail -3
done
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
