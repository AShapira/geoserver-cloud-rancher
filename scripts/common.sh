#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$REPO_ROOT/.state"
TOOLS_DIR="$REPO_ROOT/.tools"
CONFIG_PATH="$STATE_DIR/config.env"

HELM_VERSION="4.2.2"
KUBECTL_VERSION="v1.36.2"
RKE2_VERSION="v1.36.2+rke2r1"
RANCHER_VERSION="2.14.3"
HARBOR_VERSION="2.15.2"
GEOSERVER_CHART_VERSION="3.0.0"
GEOSERVER_IMAGE_VERSION="3.0.0"
PLATFORM_INFRA_CHART_VERSION="0.3.0"
GEOSERVER_SIM_CHART_VERSION="0.3.0"

POSTGIS_IMAGE="postgis/postgis:18-3.6"
PGADMIN_IMAGE="dpage/pgadmin4:9.16"
RABBITMQ_IMAGE="rabbitmq:4.3.2-management-alpine"
CURL_IMAGE="curlimages/curl:8.21.0"
K6_IMAGE="grafana/k6:2.1.0"
CANARY_IMAGE="busybox:1.38.0"
QGIS_BASE_IMAGE="kasmweb/core-ubuntu-noble:1.19.0"
PGSTAC_IMAGE="ghcr.io/stac-utils/pgstac:v0.9.11"
STAC_API_IMAGE="ghcr.io/stac-utils/stac-fastapi-pgstac:6.3.1"
GDAL_IMAGE="ghcr.io/osgeo/gdal:ubuntu-small-3.13.1"
VIEWER_BUILDER_IMAGE="node:26.4.0-alpine"
STAC_BROWSER_BUILDER_IMAGE="node:25.9.0-alpine"
VIEWER_RUNTIME_IMAGE="nginxinc/nginx-unprivileged:1.31.2-alpine"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

sudo_cmd() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run() {
  echo "+ $*" >&2
  "$@"
}

run_sudo() {
  echo "+ sudo $*" >&2
  sudo_cmd "$@"
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "Missing $CONFIG_PATH. Run ./scripts/initialize-state.sh first."
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
  set +a
}

read_defaults() {
  local defaults="$REPO_ROOT/.env.example"
  [[ -f "$defaults" ]] || die "Missing $defaults"
  set -a
  # shellcheck disable=SC1090
  source "$defaults"
  set +a
}

write_config() {
  mkdir -p "$STATE_DIR"
  local keys=(
    CLUSTER_NAME HARBOR_HOSTNAME HARBOR_PORT HARBOR_EXTERNAL_HOST HARBOR_INTERNAL_HOST
    HARBOR_IMAGE_PROJECT HARBOR_CHART_PROJECT HARBOR_ADMIN_USERNAME HARBOR_ADMIN_PASSWORD
    HARBOR_DB_PASSWORD RANCHER_HOSTNAME MAPS_HOSTNAME QGIS_HOSTNAME PGADMIN_HOSTNAME
    PGADMIN_DEFAULT_EMAIL PLATFORM_NAMESPACE GEOSERVER_NAMESPACE RANCHER_NAMESPACE
    VIEWER_IMAGE_NAME VIEWER_IMAGE_TAG QGIS_IMAGE_NAME QGIS_IMAGE_TAG PUBLISHER_IMAGE_NAME
    PUBLISHER_IMAGE_TAG STAC_BROWSER_IMAGE_NAME STAC_BROWSER_IMAGE_TAG RANCHER_BOOTSTRAP_PASSWORD
    RABBITMQ_USERNAME RABBITMQ_PASSWORD RABBITMQ_ERLANG_COOKIE POSTGRES_SUPER_USERNAME
    POSTGRES_SUPER_PASSWORD GEOSERVER_DB_USERNAME GEOSERVER_DB_PASSWORD GEOSERVER_ADMIN_USERNAME
    GEOSERVER_ADMIN_PASSWORD STAC_DB_USERNAME STAC_DB_PASSWORD QGIS_PASSWORD PGADMIN_PASSWORD
    STATE_DIR
  )
  : > "$CONFIG_PATH"
  local key
  for key in "${keys[@]}"; do
    if [[ -n "${!key+x}" ]]; then
      local value="${!key//$'\r'/}"
      printf '%s=%s\n' "$key" "$value" >> "$CONFIG_PATH"
    fi
  done
}

random_secret() {
  openssl rand -base64 "${1:-24}" | tr '+/' 'AB' | tr -d '=' | tr -d '\n'
}

hex_secret() {
  openssl rand -hex "${1:-32}" | tr -d '\n'
}

host_primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

normalize_host_without_port() {
  printf '%s\n' "$1" | sed 's#^https\?://##; s#/.*$##; s#:[0-9]\+$##'
}

harbor_client_host() {
  printf '%s\n' "${HARBOR_EXTERNAL_HOST}"
}

harbor_runtime_host() {
  printf '%s\n' "${HARBOR_INTERNAL_HOST:-$HARBOR_EXTERNAL_HOST}"
}

image_parts() {
  local image="$1" source digest tag last_slash last_colon registry repository
  source="${image%@*}"
  digest=""
  [[ "$image" == *"@"* ]] && digest="${image#*@}"
  last_slash="${source##*/}"
  tag="latest"
  if [[ "$last_slash" == *":"* ]]; then
    tag="${source##*:}"
    source="${source%:*}"
  fi
  IFS='/' read -r -a parts <<< "$source"
  registry="docker.io"
  repository="$source"
  if (( ${#parts[@]} > 1 )) && { [[ "${parts[0]}" == *.* ]] || [[ "${parts[0]}" == *:* ]] || [[ "${parts[0]}" == "localhost" ]]; }; then
    registry="${parts[0]}"
    repository="${source#*/}"
  elif (( ${#parts[@]} == 1 )); then
    repository="library/${parts[0]}"
  fi
  printf '%s\t%s\t%s\t%s\n' "$registry" "$repository" "$tag" "$digest"
}

mirror_path() {
  local registry repository tag digest path
  IFS=$'\t' read -r registry repository tag digest < <(image_parts "$1")
  path="$repository"
  [[ "$registry" != "docker.io" ]] && path="$registry/$repository"
  printf '%s:%s\n' "$path" "$tag"
}

qualified_source_image() {
  local registry repository tag digest ref
  IFS=$'\t' read -r registry repository tag digest < <(image_parts "$1")
  ref="${registry}/${repository}"
  if [[ -n "$digest" ]]; then
    printf '%s@%s\n' "$ref" "$digest"
  else
    printf '%s:%s\n' "$ref" "$tag"
  fi
}

harbor_push_image() {
  printf '%s/%s/%s\n' "$(harbor_client_host)" "$HARBOR_IMAGE_PROJECT" "$(mirror_path "$1")"
}

harbor_runtime_image() {
  printf '%s/%s/%s\n' "$(harbor_runtime_host)" "$HARBOR_IMAGE_PROJECT" "$(mirror_path "$1")"
}

local_runtime_image() {
  local name="$1" tag="$2"
  printf '%s/%s/%s:%s\n' "$(harbor_runtime_host)" "$HARBOR_IMAGE_PROJECT" "$name" "$tag"
}

local_push_image() {
  local name="$1" tag="$2"
  printf '%s/%s/%s:%s\n' "$(harbor_client_host)" "$HARBOR_IMAGE_PROJECT" "$name" "$tag"
}

helm_bin() {
  if [[ -x "$TOOLS_DIR/helm" ]]; then printf '%s\n' "$TOOLS_DIR/helm"; else printf '%s\n' "helm"; fi
}

kubectl_bin() {
  if [[ -x "$TOOLS_DIR/kubectl" ]]; then printf '%s\n' "$TOOLS_DIR/kubectl"; else printf '%s\n' "kubectl"; fi
}

podman_compose_bin() {
  if [[ -x /usr/local/bin/podman-compose ]]; then
    printf '%s\n' /usr/local/bin/podman-compose
  elif command -v podman-compose >/dev/null 2>&1; then
    command -v podman-compose
  else
    die "Missing podman-compose. Run ./scripts/install-tools.sh first."
  fi
}

kube_env() {
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
  export PATH="/var/lib/rancher/rke2/bin:$TOOLS_DIR:$PATH"
}

wait_for_url() {
  local url="$1" ca="$2" timeout="${3:-300}" userpass="${4:-}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local args=(--silent --show-error --fail --max-time 10)
    [[ -n "$ca" ]] && args+=(--cacert "$ca")
    [[ -n "$userpass" ]] && args+=(--user "$userpass")
    if curl "${args[@]}" "$url" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for $url"
}
