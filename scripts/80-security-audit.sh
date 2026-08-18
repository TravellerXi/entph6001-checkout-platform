#!/usr/bin/env bash
# Security & configuration audit.
#
# Lecture 6 makes the point that "CVE-free" is not the same as "securely configured", so this
# script runs BOTH: image CVE scanning (Trivy) and Kubernetes configuration scanning (kubesec),
# then adds targeted checks for the specific weaknesses this architecture claims to control.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

OUT="${OUT:-$HOME/ead/evidence}"
K8S="${K8S:-$HOME/ead/k8s}"
mkdir -p "$OUT"
LOG="${OUT}/security-audit-$(date +%Y%m%d-%H%M%S).log"

{
echo "############ PART 1: Kubernetes configuration scan (kubesec)"
for f in "$K8S"/20-postgres.yaml "$K8S"/30-services.yaml "$K8S"/40-gateway.yaml; do
  echo "=== $(basename "$f")"
  docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < "$f" 2>/dev/null \
    | grep -E '"object"|"score"|"id"|"selector"' | head -40 || echo "(kubesec unavailable)"
done

echo
echo "############ PART 2: Image vulnerability scan (Trivy)"
# Scan the tag that is actually deployed, not a hard-coded one. Scanning a stale tag would
# report findings that no longer exist in the running system, or hide ones that do.
TAG="${TAG:-v2}"
echo "scanning tag: ${TAG} (override with TAG=...)"
for img in "ead/pricing-fn:${TAG}" "ead/inventory-fn:${TAG}" "ead/checkout-fn:${TAG}" postgres:16-alpine nginxinc/nginx-unprivileged:1.27-alpine; do
  echo "=== ${img}"
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest image --quiet --scanners vuln \
    --severity HIGH,CRITICAL --format table "${img}" 2>/dev/null | tail -20 || echo "(scan failed)"
done

echo
echo "############ PART 3: Targeted checks against this architecture's own claims"

echo "--- 3.1 No container runs as root"
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsNonRoot}{"\n"}{end}'

echo
echo "--- 3.2 No privilege escalation, all capabilities dropped"
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\tescalation="}{.spec.containers[0].securityContext.allowPrivilegeEscalation}{"\tcaps="}{.spec.containers[0].securityContext.capabilities.drop}{"\n"}{end}'

echo
echo "--- 3.3 Service account tokens not mounted (reduces API blast radius)"
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\tautomount="}{.spec.automountServiceAccountToken}{"\n"}{end}'

echo
echo "--- 3.4 Every workload has CPU/memory limits (prevents noisy-neighbour DoS)"
kubectl -n shop get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\tlimits="}{.spec.containers[0].resources.limits}{"\n"}{end}'

echo
echo "--- 3.5 Secret is base64 only, NOT encrypted (Lecture 5 caveat, demonstrated)"
# The value itself is deliberately NOT printed: this evidence file ships with the submission,
# and the assignment forbids real credentials in the repository. Length proves retrievability.
SECRET_LEN=$(kubectl -n shop get secret db-credentials -o jsonpath='{.data.PGPASSWORD}' | wc -c)
echo "   PGPASSWORD retrievable as base64 (${SECRET_LEN} chars) by any principal holding get-secret RBAC"
echo "   value withheld from this log by design"
echo "   K3s default: secrets are stored unencrypted at rest unless encryption-at-rest is enabled:"
sudo grep -c 'secrets-encryption' /etc/systemd/system/k3s.service 2>/dev/null \
  && echo "   (flag present)" || echo "   (flag absent -> encryption at rest NOT enabled)"

echo
echo "--- 3.6 No real credentials committed to the repository"
if grep -RIn --exclude-dir=evidence -E '(PGPASSWORD|POSTGRES_PASSWORD)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/]{12,}' "$HOME/ead" 2>/dev/null | grep -v 'REPLACE_ME_AT_DEPLOY_TIME'; then
  echo "   FAIL: possible credential found above"
else
  echo "   PASS: no literal credentials in manifests or source"
fi

echo
echo "--- 3.7 Pod Security Standard enforced on the namespace"
kubectl get ns shop -o jsonpath='{.metadata.labels}'; echo
} 2>&1 | tee "$LOG"

echo "evidence: ${LOG}"
