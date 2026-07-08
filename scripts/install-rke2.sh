#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
strict_host_egress=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict-host-egress) strict_host_egress=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if command -v dnf >/dev/null 2>&1; then
  run_sudo dnf install -y kernel-modules-extra iptables-nft conntrack-tools curl
fi

run_sudo mkdir -p /etc/rancher/rke2
run_sudo cp "$STATE_DIR/certs/ca.crt" /etc/rancher/rke2/airgap-ca.crt

runtime_host="$(harbor_runtime_host)"
cat > "$STATE_DIR/registries.yaml" <<EOF
mirrors:
  "docker.io":
    endpoint:
      - "https://${runtime_host}"
    rewrite:
      "^(.*)": "${HARBOR_IMAGE_PROJECT}/\$1"
  "ghcr.io":
    endpoint:
      - "https://${runtime_host}"
    rewrite:
      "^(.*)": "${HARBOR_IMAGE_PROJECT}/ghcr.io/\$1"
  "quay.io":
    endpoint:
      - "https://${runtime_host}"
    rewrite:
      "^(.*)": "${HARBOR_IMAGE_PROJECT}/quay.io/\$1"
  "registry.k8s.io":
    endpoint:
      - "https://${runtime_host}"
    rewrite:
      "^(.*)": "${HARBOR_IMAGE_PROJECT}/registry.k8s.io/\$1"
configs:
  "${runtime_host}":
    auth:
      username: "${HARBOR_ADMIN_USERNAME}"
      password: "${HARBOR_ADMIN_PASSWORD}"
    tls:
      ca_file: /etc/rancher/rke2/airgap-ca.crt
EOF
run_sudo cp "$STATE_DIR/registries.yaml" /etc/rancher/rke2/registries.yaml

cat > "$STATE_DIR/rke2-config.yaml" <<EOF
write-kubeconfig-mode: "0644"
disable-default-registry-endpoint: true
system-default-registry: "${runtime_host}/${HARBOR_IMAGE_PROJECT}"
EOF
run_sudo cp "$STATE_DIR/rke2-config.yaml" /etc/rancher/rke2/config.yaml

installed_rke2_version=""
if command -v rke2 >/dev/null 2>&1; then
  installed_rke2_version="$(rke2 --version 2>/dev/null | awk 'NR==1 {print $3}')"
fi

if [[ "$installed_rke2_version" != "$RKE2_VERSION" ]]; then
  curl -sfL https://get.rke2.io | sudo env INSTALL_RKE2_VERSION="$RKE2_VERSION" sh -
fi

run_sudo systemctl enable --now rke2-server.service
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="/var/lib/rancher/rke2/bin:$PATH"
run_sudo /var/lib/rancher/rke2/bin/kubectl wait --for=condition=Ready node --all --timeout=300s

if [[ "$strict_host_egress" -eq 1 ]]; then
  echo "Strict host egress is intentionally not enabled automatically. Use enter-airgap.sh after deployment."
fi
echo "RKE2 is ready. Kubeconfig: /etc/rancher/rke2/rke2.yaml"
