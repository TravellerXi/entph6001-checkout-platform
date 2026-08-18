#!/usr/bin/env bash
# Build service images locally and import them into K3s containerd (Lab 4.2: no registry assumed).
set -euo pipefail

SRC="${1:-$HOME/ead/services}"
TAG="${TAG:-v1}"
IMAGES=(pricing-fn inventory-fn checkout-fn)

echo "==> building"
for svc in "${IMAGES[@]}"; do
  sudo docker build -q -t "ead/${svc}:${TAG}" "${SRC}/${svc}" >/dev/null
  echo "    ead/${svc}:${TAG}"
done

echo "==> exporting to tar"
mkdir -p "$HOME/ead/images"
sudo docker save -o "$HOME/ead/images/ead-images.tar" \
  "ead/pricing-fn:${TAG}" "ead/inventory-fn:${TAG}" "ead/checkout-fn:${TAG}"

echo "==> importing into containerd"
sudo k3s ctr images import "$HOME/ead/images/ead-images.tar" >/dev/null
sudo k3s ctr images ls -q | grep '^docker.io/ead/' || true

echo "==> done"
