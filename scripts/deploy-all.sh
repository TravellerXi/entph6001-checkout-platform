#!/usr/bin/env bash
# One-command deployment of the whole platform onto a running K3s node.
# Prerequisites: K3s installed (scripts/00-install-docker.sh for the build toolchain).
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-v2}"

echo "==> 1/5 build and import images (tag=${TAG})"
TAG="$TAG" bash "${ROOT}/scripts/10-build-images.sh" "${ROOT}/services"

echo "==> 2/5 namespace and configuration"
kubectl apply -f "${ROOT}/k8s/00-namespace.yaml"
kubectl apply -f "${ROOT}/k8s/05-serviceaccounts.yaml"
kubectl apply -f "${ROOT}/k8s/10-config.yaml"

echo "==> 3/5 database credentials (generated locally, never committed)"
bash "${ROOT}/scripts/20-create-secret.sh"

echo "==> 4/5 workloads"
kubectl apply -f "${ROOT}/k8s/20-postgres.yaml"
kubectl apply -f "${ROOT}/k8s/30-services.yaml"
kubectl apply -f "${ROOT}/k8s/41-ratelimit-middleware.yaml"
kubectl apply -f "${ROOT}/k8s/40-gateway.yaml"

echo "==> 5/5 trust boundaries"
kubectl apply -f "${ROOT}/k8s/50-networkpolicy.yaml"

echo "==> waiting for readiness"
kubectl -n shop wait --for=condition=available --timeout=300s deployment --all

echo
kubectl -n shop get pods -L tier
echo
echo "Deployed. Verify with: bash ${ROOT}/scripts/30-smoke-test.sh"
