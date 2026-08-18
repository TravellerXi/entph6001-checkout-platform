#!/usr/bin/env bash
# Compare image vulnerability posture between the v1 (single-stage) and v2 (multi-stage,
# package manager removed) builds. This is the evidence for the claim made in the report.
set -uo pipefail
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/trivy-v1-vs-v2-$(date +%Y%m%d-%H%M%S).log"

scan_count() {
  sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest image --quiet --scanners vuln --severity "$2" \
    --format json "$1" 2>/dev/null | grep -c '"VulnerabilityID"'
}

{
echo "Trivy image scan: v1 (single-stage, npm present) vs v2 (multi-stage, npm removed)"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
printf '%-26s %10s %10s\n' "IMAGE" "CRITICAL" "HIGH"
for t in v1 v2; do
  for s in pricing inventory checkout; do
    img="ead/${s}-fn:${t}"
    c=$(scan_count "$img" CRITICAL)
    h=$(scan_count "$img" HIGH)
    printf '%-26s %10s %10s\n' "$img" "$c" "$h"
  done
done

echo
echo "--- Which image is actually running in the cluster:"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
kubectl -n shop get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'

echo
echo "--- Detail of any CRITICAL still present in v2:"
for s in pricing inventory checkout; do
  sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest image --quiet --scanners vuln --severity CRITICAL \
    "ead/${s}-fn:v2" 2>/dev/null | grep -E 'CVE-|Total:' | head -5
done
echo "(no output above means no CRITICAL findings in v2)"
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
