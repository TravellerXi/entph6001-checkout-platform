#!/usr/bin/env bash
# Creates the database Secret from a locally generated random password.
# The password is never written to the repository or to shell history.
set -euo pipefail

NS="${NS:-shop}"
PASS="$(openssl rand -base64 24 | tr -d '\n/+=' | head -c 24)"

kubectl -n "$NS" create secret generic db-credentials \
  --from-literal=PGPASSWORD="$PASS" \
  --from-literal=POSTGRES_PASSWORD="$PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

unset PASS
echo "db-credentials created/updated in namespace ${NS} (value not displayed)"
