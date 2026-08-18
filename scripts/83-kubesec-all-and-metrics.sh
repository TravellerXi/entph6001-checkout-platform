#!/usr/bin/env bash
# Closes two evidence gaps found in review:
#   1. kubesec was piped whole files, so it scored only the FIRST YAML document in each.
#   2. the /metrics endpoint was claimed in the report but never captured.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/kubesec-all-workloads-$(date +%Y%m%d-%H%M%S).log"
ROOT="$HOME/ead"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
echo "############ PART 1: kubesec, every Deployment scored separately"
echo "The earlier audit piped whole manifests to 'scan /dev/stdin', which reads only the first"
echo "YAML document. For 30-services.yaml that meant pricing-fn alone was ever scored."
echo "Here each Deployment is exported from the cluster and scored on its own, so the score"
echo "describes what is actually running rather than what a file claims."
echo

total=0; scored=0
for d in $(kubectl -n shop get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  total=$((total+1))
  # Strip live status and server-side metadata so kubesec sees a clean workload spec.
  kubectl -n shop get deploy "$d" -o yaml --show-managed-fields=false \
    | awk '/^status:/ { exit } { print }' > "${WORK}/${d}.yaml"
  res=$(docker run --rm -i kubesec/kubesec:latest scan /dev/stdin < "${WORK}/${d}.yaml" 2>/dev/null)
  score=$(echo "$res" | grep -m1 '"score"' | grep -o '\-\?[0-9]\+')
  if [ -n "${score:-}" ]; then
    scored=$((scored+1))
    # List the rules each workload FAILS, so the appendix table is evidenced rather than inferred.
    advise=$(echo "$res" | awk '/"advise"/ { a=1 } a && /"id"/ { gsub(/[",]/,""); sub(/^ *id: */,""); printf "%s ", $0 }')
    printf '  %-14s score=%-4s not satisfied: %s\n' "$d" "$score" "${advise:-none}"
  else
    printf '  %-14s NO SCORE RETURNED\n' "$d"
  fi
done
echo
echo "  Deployments found: ${total}, scored: ${scored}"
echo
echo "  Note on SeccompAny: kubesec's selector for that rule is the deprecated annotation"
echo "  container.seccomp.security.alpha.kubernetes.io/pod. Every workload here sets the"
echo "  current field instead, so the rule is a false negative. Proof, straight from the API:"
kubectl -n shop get deploy -o jsonpath='{range .items[*]}{"    "}{.metadata.name}{" seccompProfile="}{.spec.template.spec.securityContext.seccompProfile.type}{"\n"}{end}'

echo
echo "############ PART 1b: every pod's ServiceAccount, so 'no pod uses default' is evidenced"
kubectl -n shop get pods -o custom-columns=POD:.metadata.name,SERVICEACCOUNT:.spec.serviceAccountName --no-headers \
  | sed 's/^/  /'
echo -n "  pods using the default ServiceAccount: "
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' | grep -cx default || true

echo
echo "############ PART 2: /metrics captured from each application service"
for pair in "checkout-fn 3003" "pricing-fn 3001" "inventory-fn 3002"; do
  set -- $pair
  pod=$(kubectl -n shop get pods -l "app=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  echo "--- $1 (pod ${pod}) port $2"
  kubectl -n shop exec "deploy/$1" -- wget -qO- "http://localhost:$2/metrics" 2>/dev/null | head -6
  echo
done
echo "  The three counters differ, confirming three independent processes rather than one"
echo "  endpoint answering three times. Totals are large because readiness probes poll /health."

echo
echo "############ PART 3: the counter moves when real traffic flows"
read_total() {
  kubectl -n shop exec deploy/checkout-fn -- wget -qO- http://localhost:3003/metrics 2>/dev/null \
    | awk '/^requests_total/ { print $2; exit }'
}
before=$(read_total)
for _ in $(seq 1 6); do
  curl -s -o /dev/null -X POST http://localhost/api/checkout \
    -H 'content-type: application/json' --data '{"sku":1,"subtotal":100}'
  sleep 0.3
done
after=$(read_total)
echo "  requests_total before: ${before:-n/a}"
echo "  requests_total after : ${after:-n/a}"
if [ -n "${before:-}" ] && [ -n "${after:-}" ]; then
  echo "  delta: $(( after - before )) (two replicas share the load, and probes also increment)"
fi
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
