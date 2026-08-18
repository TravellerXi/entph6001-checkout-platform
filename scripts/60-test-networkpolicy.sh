#!/usr/bin/env bash
# Security validation: prove the public / internal / protected trust boundaries are ENFORCED,
# not merely drawn. Each case states the expectation, then tests it.
#
# K3s bundles the kube-router network-policy controller, so NetworkPolicy is actually enforced;
# on a cluster without a policy-capable CNI these objects would be silently inert, which is why
# the negative controls below matter.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
mkdir -p "$OUT"
LOG="${OUT}/networkpolicy-$(date +%Y%m%d-%H%M%S).log"

pod_of() { kubectl -n shop get pod -l "app=$1" -o jsonpath='{.items[0].metadata.name}'; }

http_probe() { # pod, url, expectation
  local pod="$1" url="$2" expect="$3" result
  if kubectl -n shop exec "$pod" -- wget -q -T 4 -O /dev/null "$url" >/dev/null 2>&1; then
    result="ALLOWED"
  else
    result="BLOCKED"
  fi
  printf '%-46s expected=%-8s actual=%-8s %s\n' "$4" "$expect" "$result" \
    "$([ "$expect" = "$result" ] && echo PASS || echo FAIL)"
}

tcp_probe() { # pod, host, port, expectation, label
  local pod="$1" host="$2" port="$3" expect="$4" result
  if kubectl -n shop exec "$pod" -- nc -z -w 4 "$host" "$port" >/dev/null 2>&1; then
    result="ALLOWED"
  else
    result="BLOCKED"
  fi
  printf '%-46s expected=%-8s actual=%-8s %s\n' "$5" "$expect" "$result" \
    "$([ "$expect" = "$result" ] && echo PASS || echo FAIL)"
}

{
GW=$(pod_of gateway)
CO=$(pod_of checkout-fn)
PR=$(pod_of pricing-fn)
IN=$(pod_of inventory-fn)

echo "== pods under test"
echo "   gateway=$GW checkout=$CO pricing=$PR inventory=$IN"
echo
echo "== A. Allowed paths (the architecture must still work)"
http_probe "$GW" "http://checkout-svc/health"   ALLOWED "A1 gateway   -> checkout-svc  (documented)"
http_probe "$CO" "http://pricing-svc/health"    ALLOWED "A2 checkout  -> pricing-svc   (documented)"
http_probe "$CO" "http://inventory-svc/health"  ALLOWED "A3 checkout  -> inventory-svc (documented)"
tcp_probe  "$IN" "postgres-svc" 5432            ALLOWED "A4 inventory -> postgres:5432 (documented)"

echo
echo "== B. Denied paths (lateral movement must fail)"
http_probe "$GW" "http://pricing-svc/health"    BLOCKED "B1 gateway   -> pricing-svc   (bypass tier)"
http_probe "$GW" "http://inventory-svc/health"  BLOCKED "B2 gateway   -> inventory-svc (bypass tier)"
tcp_probe  "$GW" "postgres-svc" 5432            BLOCKED "B3 gateway   -> postgres:5432 (public->protected)"
tcp_probe  "$PR" "postgres-svc" 5432            BLOCKED "B4 pricing   -> postgres:5432 (not data owner)"
tcp_probe  "$CO" "postgres-svc" 5432            BLOCKED "B5 checkout  -> postgres:5432 (not data owner)"
http_probe "$PR" "http://inventory-svc/health"  BLOCKED "B6 pricing   -> inventory-svc (peer isolation)"

echo
echo "== D. Egress control (a compromised workload must not phone home)"
# Lab 12 treats egress governance as half of east-west control: ingress rules alone still leave
# every pod free to reach the internet, which is the data-exfiltration and C2 path.
http_probe "$CO" "http://example.com"            BLOCKED "D1 checkout  -> internet          (egress deny)"
http_probe "$PR" "http://example.com"            BLOCKED "D2 pricing   -> internet          (egress deny)"
http_probe "$IN" "http://example.com"            BLOCKED "D3 inventory -> internet          (egress deny)"
http_probe "$GW" "http://example.com"            BLOCKED "D4 gateway   -> internet          (egress deny)"
tcp_probe  "$IN" "169.254.169.254" 80            BLOCKED "D5 inventory -> cloud metadata     (SSRF path)"

echo
echo "== C. Compromised-workload simulation (unlabelled pod, default-deny must hold)"
kubectl -n shop delete pod attacker --ignore-not-found >/dev/null 2>&1 || true
kubectl -n shop run attacker --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"attacker","image":"busybox:1.36","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  >/dev/null
kubectl -n shop wait --for=condition=ready pod/attacker --timeout=60s >/dev/null

http_probe "attacker" "http://checkout-svc/health"  BLOCKED "C1 attacker -> checkout-svc"
http_probe "attacker" "http://pricing-svc/health"   BLOCKED "C2 attacker -> pricing-svc"
http_probe "attacker" "http://inventory-svc/health" BLOCKED "C3 attacker -> inventory-svc"
tcp_probe  "attacker" "postgres-svc" 5432           BLOCKED "C4 attacker -> postgres:5432"

kubectl -n shop delete pod attacker --ignore-not-found >/dev/null 2>&1 || true

echo
echo "== policies in force"
kubectl -n shop get networkpolicy
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
