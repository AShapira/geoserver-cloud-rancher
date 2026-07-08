#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

recreate=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate) recreate=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ -f "$CONFIG_PATH" ]] || "$SCRIPT_DIR/initialize-state.sh"
load_config
need_cmd curl
need_cmd podman
need_cmd envsubst
run_sudo true

harbor_root="$STATE_DIR/harbor"
installer_dir="$harbor_root/installer"
mkdir -p "$harbor_root/data" "$harbor_root/logs" "$TOOLS_DIR"
installer_tgz="$TOOLS_DIR/harbor-online-installer-v${HARBOR_VERSION}.tgz"

if [[ ! -f "$installer_tgz" ]]; then
  curl -fsSL "https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-online-installer-v${HARBOR_VERSION}.tgz" -o "$installer_tgz"
fi

if [[ -d "$installer_dir" ]]; then
  run_sudo rm -rf "$installer_dir"
fi
mkdir -p "$installer_dir"
tar -xzf "$installer_tgz" -C "$installer_dir" --strip-components=1
sed -i \
  -e 's/docker run /podman run /' \
  -e 's#goharbor/prepare:#docker.io/goharbor/prepare:#' \
  "$installer_dir/prepare"
mkdir -p "$installer_dir/common/config"

export HARBOR_HOSTNAME HARBOR_PORT HARBOR_EXTERNAL_HOST HARBOR_ADMIN_PASSWORD HARBOR_DB_PASSWORD
export HARBOR_CERT="$STATE_DIR/certs/server.crt"
export HARBOR_KEY="$STATE_DIR/certs/server.key"
export HARBOR_DATA_VOLUME="$harbor_root/data"
export HARBOR_LOG_DIR="$harbor_root/logs"
envsubst < "$REPO_ROOT/infra/harbor/harbor.yml.template" > "$installer_dir/harbor.yml"

pushd "$installer_dir" >/dev/null
run_sudo ./prepare --with-trivy
sed -i 's#image: goharbor/#image: docker.io/goharbor/#' docker-compose.yml
python3 - <<'PY'
import os
import yaml
with open("docker-compose.yml", "r", encoding="utf-8") as handle:
    compose = yaml.safe_load(handle)
for service in compose.get("services", {}).values():
    service.pop("logging", None)
    volumes = service.get("volumes", [])
    for index, volume in enumerate(volumes):
        if isinstance(volume, str) and volume.startswith("./"):
            source, rest = volume.split(":", 1)
            volumes[index] = f"{os.path.abspath(source)}:{rest}"
        elif isinstance(volume, dict) and isinstance(volume.get("source"), str) and volume["source"].startswith("./"):
            volume["source"] = os.path.abspath(volume["source"])
with open("docker-compose.yml", "w", encoding="utf-8") as handle:
    yaml.safe_dump(compose, handle, sort_keys=False)
PY
if sudo_cmd test -x /usr/local/bin/podman-compose; then
  compose=(/usr/local/bin/podman-compose -f docker-compose.yml)
elif command -v podman-compose >/dev/null 2>&1; then
  compose=("$(command -v podman-compose)" -f docker-compose.yml)
elif [[ -x "$TOOLS_DIR/docker-compose" ]]; then
  compose=(env DOCKER_HOST=unix:///run/podman/podman.sock "$TOOLS_DIR/docker-compose" -f docker-compose.yml)
else
  compose=(podman compose -f docker-compose.yml)
fi
run_sudo "${compose[@]}" down
run_sudo "${compose[@]}" up -d
popd >/dev/null

wait_for_url "https://${HARBOR_EXTERNAL_HOST}/api/v2.0/ping" "$STATE_DIR/certs/ca.crt" 900
deadline=$((SECONDS + 180))
until curl -fsS --cacert "$STATE_DIR/certs/ca.crt" -u "${HARBOR_ADMIN_USERNAME}:${HARBOR_ADMIN_PASSWORD}" \
  "https://${HARBOR_EXTERNAL_HOST}/api/v2.0/projects" >/dev/null; do
  (( SECONDS < deadline )) || die "Timed out waiting for Harbor project API."
  sleep 5
done

for project in "$HARBOR_IMAGE_PROJECT" "$HARBOR_CHART_PROJECT"; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$STATE_DIR/certs/ca.crt" \
    -u "${HARBOR_ADMIN_USERNAME}:${HARBOR_ADMIN_PASSWORD}" \
    "https://${HARBOR_EXTERNAL_HOST}/api/v2.0/projects/${project}")"
  if [[ "$status" == "404" ]]; then
    curl -fsS --cacert "$STATE_DIR/certs/ca.crt" -u "${HARBOR_ADMIN_USERNAME}:${HARBOR_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -d "{\"project_name\":\"${project}\",\"metadata\":{\"public\":\"false\"}}" \
      "https://${HARBOR_EXTERNAL_HOST}/api/v2.0/projects" >/dev/null
  fi
done

deadline=$((SECONDS + 180))
until printf '%s\n' "$HARBOR_ADMIN_PASSWORD" | run_sudo podman login "${HARBOR_EXTERNAL_HOST}" \
  --username "$HARBOR_ADMIN_USERNAME" --password-stdin --cert-dir "/etc/containers/certs.d/${HARBOR_EXTERNAL_HOST}"; do
  (( SECONDS < deadline )) || die "Timed out waiting for Harbor registry login."
  sleep 5
done
echo "Harbor is ready at https://${HARBOR_EXTERNAL_HOST}"
