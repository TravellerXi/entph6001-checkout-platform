#!/usr/bin/env bash
# Full detail of the v1 findings, so the CVE-level evidence behind the report's interpretation
# survives even after the audit script is re-run against the deployed tag.
set -uo pipefail
OUT="${OUT:-$HOME/ead/evidence}"; mkdir -p "$OUT"
LOG="${OUT}/trivy-v1-detail-$(date +%Y%m%d-%H%M%S).log"

{
echo "Detailed HIGH/CRITICAL findings in the v1 (single-stage) image."
echo "Retained because the report argues these were unreachable at runtime and came from the"
echo "bundled npm CLI rather than from application dependencies."
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --quiet --scanners vuln --severity HIGH,CRITICAL \
  --format table ead/checkout-fn:v1 2>/dev/null

echo
echo "--- Where the vulnerable packages live inside the image (v1):"
sudo docker run --rm --entrypoint sh ead/checkout-fn:v1 -c \
  'ls -d /usr/local/lib/node_modules/npm 2>/dev/null && echo "npm CLI present in v1" ; ls /app/node_modules 2>/dev/null | head -10' 2>/dev/null

echo
echo "--- Same paths in the v2 image:"
sudo docker run --rm --entrypoint sh ead/checkout-fn:v2 -c \
  'ls -d /usr/local/lib/node_modules/npm 2>/dev/null || echo "npm CLI absent in v2" ; ls /app/node_modules 2>/dev/null | head -10' 2>/dev/null
} 2>&1 | tee "$LOG"
echo "evidence: ${LOG}"
