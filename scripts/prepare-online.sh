#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

force_mirror=0
include_rancher_release_image_set=0
skip_mirror=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-mirror) force_mirror=1 ;;
    --include-rancher-release-image-set) include_rancher_release_image_set=1 ;;
    --skip-mirror) skip_mirror=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

"$SCRIPT_DIR/install-tools.sh"
"$SCRIPT_DIR/initialize-state.sh"
"$SCRIPT_DIR/start-harbor.sh"
load_config
helm="$(helm_bin)"

dist="$REPO_ROOT/dist"
chart_dist="$dist/charts"
mkdir -p "$chart_dist"
rancher_images_file="$STATE_DIR/rancher-images-v${RANCHER_VERSION}.txt"
rke2_images_file="$STATE_DIR/rke2-images-${RKE2_VERSION}.txt"
if [[ "$include_rancher_release_image_set" -eq 1 ]]; then
  curl -fsSL "https://github.com/rancher/rancher/releases/download/v${RANCHER_VERSION}/rancher-images.txt" -o "$rancher_images_file"
fi
if [[ "$force_mirror" -eq 1 || ! -f "$rke2_images_file" ]]; then
  if ! curl -fsSL "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images.linux-amd64.txt" -o "$rke2_images_file"; then
    echo "Warning: could not download RKE2 image list for ${RKE2_VERSION}; continuing with the static seed list." >&2
    rm -f "$rke2_images_file"
  fi
fi

images=(
  "rancher/rancher:v${RANCHER_VERSION}"
  "rancher/mirrored-pause:3.6"
  "rancher/klipper-helm:v0.10.0-build20260513"
  "rancher/klipper-lb:v0.4.17"
  "rancher/local-path-provisioner:v0.0.36"
  "rancher/mirrored-coredns-coredns:1.14.3"
  "rancher/mirrored-metrics-server:v0.8.1"
  "$CANARY_IMAGE"
  "rancher/shell:v0.7.0"
  "rancher/fleet:v0.15.2"
  "rancher/fleet-agent:v0.15.2"
  "rancher/cluster-api-controller:v1.12.7"
  "rancher/rancher-webhook:v0.10.6"
  "rancher/system-upgrade-controller:v0.19.1"
  "rancher/turtles:v0.26.2"
  "rancher/kuberlr-kubectl:v7.0.3"
  "geoservercloud/geoserver-cloud-gateway:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-webui:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-rest:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-wms:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-wfs:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-gwc:${GEOSERVER_IMAGE_VERSION}"
  "geoservercloud/geoserver-cloud-wcs:${GEOSERVER_IMAGE_VERSION}"
  "$POSTGIS_IMAGE" "$PGADMIN_IMAGE" "$RABBITMQ_IMAGE" "$CURL_IMAGE" "$K6_IMAGE" "$CANARY_IMAGE"
  "$PGSTAC_IMAGE" "$STAC_API_IMAGE" "$VIEWER_BUILDER_IMAGE" "$STAC_BROWSER_BUILDER_IMAGE" "$VIEWER_RUNTIME_IMAGE" "$QGIS_BASE_IMAGE" "$GDAL_IMAGE"
)

if [[ -f "$rke2_images_file" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[$'\t\r\n ']}"
    [[ -n "$line" ]] && images+=("$line")
  done < "$rke2_images_file"
fi

if [[ "$include_rancher_release_image_set" -eq 1 && -f "$rancher_images_file" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[$'\t\r\n ']}"
    [[ -n "$line" ]] && images+=("$line")
  done < "$rancher_images_file"
fi

manifest_path="$dist/image-manifest.json"
if [[ "$skip_mirror" -eq 0 ]]; then
  mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)
  tmp_manifest="$(mktemp)"
  printf '[\n' > "$tmp_manifest"
  first=1
  index=0
  total="${#images[@]}"

  for source in "${images[@]}"; do
    index=$((index + 1))
    pull_ref="$(qualified_source_image "$source")"
    push="$(harbor_push_image "$source")"
    runtime="$(harbor_runtime_image "$source")"
    echo "[$index/$total] mirroring $source"
    run_sudo podman pull --platform linux/amd64 "$pull_ref"
    run_sudo podman tag "$pull_ref" "$push"
    if ! sudo_cmd podman push "$push"; then
      echo "Repacking legacy multi-platform manifest as linux/amd64: $source"
      single="$STATE_DIR/single-platform-image"
      mkdir -p "$single"
      printf 'ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n' > "$single/Dockerfile"
      run_sudo podman build --platform linux/amd64 --build-arg "BASE_IMAGE=$pull_ref" --tag "$push" "$single"
      run_sudo podman push "$push"
    fi
    digest="$(sudo_cmd podman image inspect "$pull_ref" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    [[ "$first" -eq 0 ]] && printf ',\n' >> "$tmp_manifest"
    first=0
    jq -n --arg source "$source" --arg push "$push" --arg runtime "$runtime" --arg digest "$digest" \
      '{source:$source,push:$push,runtime:$runtime,digest:$digest}' >> "$tmp_manifest"
  done

  printf '\n]\n' >> "$tmp_manifest"
  mv "$tmp_manifest" "$manifest_path"
elif [[ ! -f "$manifest_path" ]]; then
  printf '[]\n' > "$manifest_path"
fi

build_local() {
  local source_name="$1" image_name="$2" tag="$3" context="$4"
  shift 4
  local push runtime digest
  push="$(local_push_image "$image_name" "$tag")"
  runtime="$(local_runtime_image "$image_name" "$tag")"
  run_sudo podman build "$@" --tag "$push" "$context"
  run_sudo podman push "$push"
  digest="$(sudo_cmd podman image inspect "$push" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  jq --arg source "$source_name" --arg push "$push" --arg runtime "$runtime" --arg digest "$digest" \
    '. += [{source:$source,push:$push,runtime:$runtime,digest:$digest}]' "$manifest_path" > "$manifest_path.tmp"
  mv "$manifest_path.tmp" "$manifest_path"
}

build_local local/viewer "$VIEWER_IMAGE_NAME" "$VIEWER_IMAGE_TAG" "$REPO_ROOT/viewer"
build_local local/qgis "$QGIS_IMAGE_NAME" "$QGIS_IMAGE_TAG" "$REPO_ROOT/qgis" --platform linux/amd64 --build-arg "QGIS_BASE_IMAGE=$QGIS_BASE_IMAGE"
build_local local/publisher "$PUBLISHER_IMAGE_NAME" "$PUBLISHER_IMAGE_TAG" "$REPO_ROOT/publisher" --platform linux/amd64 --build-arg "GDAL_IMAGE=$GDAL_IMAGE"
build_local local/stac-browser "$STAC_BROWSER_IMAGE_NAME" "$STAC_BROWSER_IMAGE_TAG" "$REPO_ROOT/stac-browser" --platform linux/amd64 --build-arg "STAC_BROWSER_VERSION=4.0.1"

helm_home="$STATE_DIR/helm"
export HELM_CONFIG_HOME="$helm_home/config" HELM_CACHE_HOME="$helm_home/cache" HELM_DATA_HOME="$helm_home/data"
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
run "$helm" repo add gscloud https://camptocamp.github.io/helm-geoserver-cloud --force-update
run "$helm" repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
run "$helm" repo update
run "$helm" dependency update "$REPO_ROOT/charts/geoserver-cloud-sim"
run "$helm" lint "$REPO_ROOT/charts/platform-infra"
run "$helm" lint "$REPO_ROOT/charts/geoserver-cloud-sim"
run "$helm" package "$REPO_ROOT/charts/platform-infra" --destination "$chart_dist"
run "$helm" package "$REPO_ROOT/charts/geoserver-cloud-sim" --destination "$chart_dist"
rm -f "$chart_dist/rancher-${RANCHER_VERSION}.tgz"
run "$helm" pull rancher-latest/rancher --version "$RANCHER_VERSION" --destination "$chart_dist"

printf '%s\n' "$HARBOR_ADMIN_PASSWORD" | "$helm" registry login "$(harbor_client_host)" \
  --username "$HARBOR_ADMIN_USERNAME" --password-stdin --ca-file "$STATE_DIR/certs/ca.crt"
for package in "$chart_dist"/*.tgz; do
  [[ "$(basename "$package")" == rancher-* ]] && continue
  run "$helm" push "$package" "oci://$(harbor_client_host)/${HARBOR_CHART_PROJECT}"
done
cp "$chart_dist/rancher-${RANCHER_VERSION}.tgz" "$STATE_DIR/"
echo "Prepared image manifest: $manifest_path"
