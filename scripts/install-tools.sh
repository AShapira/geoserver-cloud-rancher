#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "$TOOLS_DIR"

if command -v dnf >/dev/null 2>&1; then
  run_sudo dnf install -y podman curl jq openssl tar gzip gettext iproute iptables-nft firewalld python3 nodejs npm git
  if ! sudo_cmd dnf install -y podman-compose; then
    echo "podman-compose package is unavailable; installing the Python provider for rootful Podman Compose." >&2
    run_sudo python3 -m pip install podman-compose
  fi
fi

if [[ ! -x "$TOOLS_DIR/helm" || "${1:-}" == "--force" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o "$tmp/helm.tgz"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  install -m 0755 "$tmp/linux-amd64/helm" "$TOOLS_DIR/helm"
  rm -rf "$tmp"
fi

if [[ ! -x "$TOOLS_DIR/kubectl" || "${1:-}" == "--force" ]]; then
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o "$TOOLS_DIR/kubectl"
  chmod 0755 "$TOOLS_DIR/kubectl"
fi

run_sudo systemctl enable --now podman.socket
podman --version
"$(podman_compose_bin)" --version
"$(helm_bin)" version --short
"$(kubectl_bin)" version --client=true || true
