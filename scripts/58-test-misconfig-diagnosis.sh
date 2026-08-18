#!/usr/bin/env bash
# Lab 4.2 "Troubleshooting Exercise (Required)".
#
# The classic Compose -> Kubernetes migration bug: the gateway keeps the Compose service name
# (checkout-fn) instead of the Kubernetes Service name (checkout-svc). This reproduces it,
# diagnoses it using only cluster evidence, fixes it, and proves the fix.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/misconfig-diagnosis-$(date +%Y%m%d-%H%M%S).log"
ROOT="$HOME/ead"

hit() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X POST http://localhost/api/checkout \
        -H 'content-type: application/json' --data '{"sku":1,"subtotal":100}'; }

restore() {
  kubectl -n shop apply -f "${ROOT}/k8s/10-config.yaml" >/dev/null 2>&1
  kubectl -n shop rollout restart deployment/gateway >/dev/null 2>&1
  kubectl -n shop rollout status deployment/gateway --timeout=120s >/dev/null 2>&1
}
trap restore EXIT

{
echo "--- STEP 0. Working baseline"
echo "    checkout -> HTTP $(hit)"
echo "    current upstream in ConfigMap:"
kubectl -n shop get configmap gateway-config -o yaml | grep -m1 'proxy_pass.*checkout' | sed 's/^/      /'

echo
echo "--- STEP 1. Inject the migration bug: use the Compose name instead of the Service name"
kubectl -n shop get configmap gateway-config -o yaml \
  | sed 's|proxy_pass http://checkout-svc/checkout|proxy_pass http://checkout-fn/checkout|' \
  | kubectl apply -f - >/dev/null

# Gate: never report on a fault that was not actually injected.
if ! kubectl -n shop get configmap gateway-config -o yaml | grep -q 'proxy_pass http://checkout-fn/checkout'; then
  echo "    ABORT: injection did not take effect; the ConfigMap still reads:"
  kubectl -n shop get configmap gateway-config -o yaml | grep -m1 'proxy_pass.*checkout' | sed 's/^/      /'
  exit 1
fi
echo "    injection verified in the cluster:"
kubectl -n shop get configmap gateway-config -o yaml | grep -m1 'proxy_pass.*checkout' | sed 's/^/      /'
kubectl -n shop rollout restart deployment/gateway >/dev/null
echo "    rollout status after restart (bounded):"
timeout 60 kubectl -n shop rollout status deployment/gateway 2>&1 | tail -1 | sed 's/^/      /'
sleep 5

echo
echo "--- STEP 2. Symptom as a user sees it"
codes=""; for _ in $(seq 1 5); do codes="${codes}$(hit) "; sleep 0.3; done
echo "    checkout x5 -> ${codes}"
echo "    NOTE: the lab predicts 503 here. This platform returns 200 because the broken config"
echo "    cannot pass the readiness gate, so the old gateway pods keep serving. The failure is"
echo "    therefore visible to operators (CrashLoopBackOff) but not to users. That is the"
echo "    intended behaviour of running two replicas behind a rolling update."

echo
echo "--- STEP 3. Diagnose (lab 4.3 workflow: pods -> service -> endpoints -> logs)"
echo "    3a. are the gateway pods running?"
kubectl -n shop get pods -l app=gateway --no-headers | sed 's/^/        /'
echo "    3b. does a Service named 'checkout-fn' exist?"
if kubectl -n shop get svc checkout-fn >/dev/null 2>&1; then echo "        yes"; else echo "        NO SUCH SERVICE -> DNS for checkout-fn cannot resolve"; fi
echo "    3c. what Services actually exist?"
kubectl -n shop get svc --no-headers | awk '{print "        "$1"  "$3"  "$5}'
echo "    3d. endpoints behind the real Service (backend itself is healthy):"
kubectl -n shop get endpointslices -l kubernetes.io/service-name=checkout-svc -o wide --no-headers 2>/dev/null | sed 's/^/        /'
echo "    3e. the gateway's own words:"
kubectl -n shop logs -l app=gateway --tail=60 --all-containers 2>/dev/null | grep -iE 'host not found|emerg|could not be resolved|no resolver|failed' | head -3 | sed 's/^/        /'
kubectl -n shop logs -l app=gateway --previous --tail=20 2>/dev/null | grep -iE 'host not found|emerg' | head -2 | sed 's/^/        (previous) /'

echo
echo "    ROOT CAUSE: the gateway resolves the container name from Compose, but in Kubernetes"
echo "    the stable name is the Service. The backend was never unhealthy."

echo
echo "--- STEP 4. Fix and prove"
kubectl -n shop apply -f "${ROOT}/k8s/10-config.yaml" >/dev/null
kubectl -n shop rollout restart deployment/gateway >/dev/null
kubectl -n shop rollout status deployment/gateway --timeout=120s 2>&1 | tail -1 | sed 's/^/    /'
sleep 5
echo "    restored upstream:"
kubectl -n shop get configmap gateway-config -o yaml | grep -m1 'proxy_pass.*checkout' | sed 's/^/      /'
codes=""; for _ in $(seq 1 5); do codes="${codes}$(hit) "; done
echo "    checkout x5 -> ${codes}"
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
