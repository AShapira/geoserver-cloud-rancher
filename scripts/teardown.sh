#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

purge=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) purge=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ -f "$CONFIG_PATH" ]] && load_config || true
kube_env || true
helm="$(helm_bin)"
if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
  "$helm" uninstall gscloud -n "${GEOSERVER_NAMESPACE:-gscloud}" || true
  "$helm" uninstall platform -n "${PLATFORM_NAMESPACE:-platform-infra}" || true
  "$helm" uninstall rancher -n "${RANCHER_NAMESPACE:-cattle-system}" || true
fi
run_sudo systemctl stop rke2-server.service 2>/dev/null || true
if [[ -f "$STATE_DIR/harbor/installer/docker-compose.yml" ]]; then
  pushd "$STATE_DIR/harbor/installer" >/dev/null
  if podman compose version >/dev/null 2>&1; then run_sudo podman compose down; elif command -v podman-compose >/dev/null 2>&1; then run_sudo podman-compose down; fi
  popd >/dev/null
fi
if [[ "$purge" -eq 1 ]]; then
  state_real="$(realpath "$STATE_DIR")"
  root_real="$(realpath "$REPO_ROOT")"
  [[ "$state_real" == "$root_real"/.state ]] || die "Refusing to remove unexpected state path: $state_real"
  rm -rf "$state_real"
  echo "Removed generated state."
else
  echo "Stopped the environment and preserved generated state."
fi
