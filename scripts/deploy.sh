#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

tuned=0
enable_wms_hpa=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tuned) tuned=1 ;;
    --enable-wms-hpa) enable_wms_hpa=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

"$SCRIPT_DIR/initialize-state.sh" --skip-trust
load_config
kube_env
helm="$(helm_bin)"
kubectl="$(kubectl_bin)"
ca="$STATE_DIR/certs/ca.crt"
cert="$STATE_DIR/certs/server.crt"
key="$STATE_DIR/certs/server.key"

printf '%s\n' "$HARBOR_ADMIN_PASSWORD" | "$helm" registry login "$(harbor_client_host)" \
  --username "$HARBOR_ADMIN_USERNAME" --password-stdin --ca-file "$ca"

for namespace in "$PLATFORM_NAMESPACE" "$GEOSERVER_NAMESPACE"; do
  run "$kubectl" create namespace "$namespace" --dry-run=client -o yaml | "$kubectl" apply -f -
  role="platform"
  [[ "$namespace" == "$GEOSERVER_NAMESPACE" ]] && role="geoserver"
  run "$kubectl" label namespace "$namespace" "airgap.geoserver/role=$role" --overwrite

  docker_auth="$(printf '%s:%s' "$HARBOR_ADMIN_USERNAME" "$HARBOR_ADMIN_PASSWORD" | base64 -w0)"
  docker_config="$STATE_DIR/harbor-dockerconfig-${namespace}.json"
  cat > "$docker_config" <<EOF
{"auths":{"$(harbor_runtime_host)":{"username":"${HARBOR_ADMIN_USERNAME}","password":"${HARBOR_ADMIN_PASSWORD}","auth":"${docker_auth}"},"$(harbor_client_host)":{"username":"${HARBOR_ADMIN_USERNAME}","password":"${HARBOR_ADMIN_PASSWORD}","auth":"${docker_auth}"}}}
EOF
  run "$kubectl" -n "$namespace" create secret generic harbor-credentials \
    --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$docker_config" \
    --dry-run=client -o yaml | "$kubectl" apply -f -
done

run "$kubectl" -n "$GEOSERVER_NAMESPACE" create secret tls maps-tls --cert="$cert" --key="$key" --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$GEOSERVER_NAMESPACE" create secret tls qgis-tls --cert="$cert" --key="$key" --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$PLATFORM_NAMESPACE" create secret tls pgadmin-tls --cert="$cert" --key="$key" --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$GEOSERVER_NAMESPACE" create configmap airgap-ca --from-file=ca.crt="$ca" --dry-run=client -o yaml | "$kubectl" apply -f -
"$SCRIPT_DIR/prepare-rke2-storage.sh"

run "$helm" upgrade --install platform "oci://$(harbor_client_host)/${HARBOR_CHART_PROJECT}/platform-infra" \
  --version "$PLATFORM_INFRA_CHART_VERSION" --namespace "$PLATFORM_NAMESPACE" \
  --set-string "registry.pullSecret=harbor-credentials" \
  --set-string "images.busybox=$(harbor_runtime_image "$CANARY_IMAGE")" \
  --set-string "images.postgis=$(harbor_runtime_image "$POSTGIS_IMAGE")" \
  --set-string "images.pgadmin=$(harbor_runtime_image "$PGADMIN_IMAGE")" \
  --set-string "images.rabbitmq=$(harbor_runtime_image "$RABBITMQ_IMAGE")" \
  --set-string "images.pgstac=$(harbor_runtime_image "$PGSTAC_IMAGE")" \
  --set-string "secrets.postgresSuperUsername=$POSTGRES_SUPER_USERNAME" \
  --set-string "secrets.postgresSuperPassword=$POSTGRES_SUPER_PASSWORD" \
  --set-string "secrets.geoserverUsername=$GEOSERVER_DB_USERNAME" \
  --set-string "secrets.geoserverPassword=$GEOSERVER_DB_PASSWORD" \
  --set-string "secrets.rabbitmqUsername=$RABBITMQ_USERNAME" \
  --set-string "secrets.rabbitmqPassword=$RABBITMQ_PASSWORD" \
  --set-string "secrets.rabbitmqErlangCookie=$RABBITMQ_ERLANG_COOKIE" \
  --set-string "secrets.pgadminPassword=$PGADMIN_PASSWORD" \
  --set-string "secrets.stacUsername=$STAC_DB_USERNAME" \
  --set-string "secrets.stacPassword=$STAC_DB_PASSWORD" \
  --set-string "pgadmin.host=$PGADMIN_HOSTNAME" \
  --set-string "pgadmin.email=$PGADMIN_DEFAULT_EMAIL" \
  --wait --timeout 10m

geo_args=(
  upgrade --install gscloud "oci://$(harbor_client_host)/${HARBOR_CHART_PROJECT}/geoserver-cloud-sim"
  --version "$GEOSERVER_SIM_CHART_VERSION" --namespace "$GEOSERVER_NAMESPACE"
  --set-string "registry.pullSecret=harbor-credentials"
  --set-string "geoservercloud.global.image.pullSecrets[0].name=harbor-credentials"
  --set-string "runtimeSecrets.rabbitmqUsername=$RABBITMQ_USERNAME"
  --set-string "runtimeSecrets.rabbitmqPassword=$RABBITMQ_PASSWORD"
  --set-string "runtimeSecrets.pgconfigUsername=$GEOSERVER_DB_USERNAME"
  --set-string "runtimeSecrets.pgconfigPassword=$GEOSERVER_DB_PASSWORD"
  --set-string "runtimeSecrets.geoserverAdminUsername=$GEOSERVER_ADMIN_USERNAME"
  --set-string "runtimeSecrets.geoserverAdminPassword=$GEOSERVER_ADMIN_PASSWORD"
  --set-string "runtimeSecrets.qgisPassword=$QGIS_PASSWORD"
  --set-string "runtimeSecrets.stacUsername=$STAC_DB_USERNAME"
  --set-string "runtimeSecrets.stacPassword=$STAC_DB_PASSWORD"
  --set-string "viewer.image=$(local_runtime_image "$VIEWER_IMAGE_NAME" "$VIEWER_IMAGE_TAG")"
  --set-string "qgis.host=$QGIS_HOSTNAME"
  --set-string "qgis.image=$(local_runtime_image "$QGIS_IMAGE_NAME" "$QGIS_IMAGE_TAG")"
  --set-string "stac.host=$MAPS_HOSTNAME"
  --set-string "stac.apiImage=$(harbor_runtime_image "$STAC_API_IMAGE")"
  --set-string "stac.browserImage=$(local_runtime_image "$STAC_BROWSER_IMAGE_NAME" "$STAC_BROWSER_IMAGE_TAG")"
  --set-string "stac.gatewayImage=$(harbor_runtime_image "$VIEWER_RUNTIME_IMAGE")"
  --set-string "publisher.image=$(local_runtime_image "$PUBLISHER_IMAGE_NAME" "$PUBLISHER_IMAGE_TAG")"
  --set-string "publisher.publicBaseUrl=https://${MAPS_HOSTNAME}"
)
if [[ "$tuned" -eq 1 ]]; then geo_args+=(--values "$REPO_ROOT/charts/geoserver-cloud-sim/values-tuning.yaml"); fi
if [[ "$enable_wms_hpa" -eq 1 ]]; then geo_args+=(--set geoservercloud.geoserver.services.wms.hpa.enabled=true); fi
geo_args+=(--wait --timeout 20m)
run "$helm" "${geo_args[@]}"

"$SCRIPT_DIR/register-rancher-catalog.sh"
echo "Viewer: https://${MAPS_HOSTNAME}"
echo "STAC Browser: https://${MAPS_HOSTNAME}/stac/"
echo "QGIS: https://${QGIS_HOSTNAME} (user: kasm_user)"
echo "pgAdmin: https://${PGADMIN_HOSTNAME} (user: ${PGADMIN_DEFAULT_EMAIL})"
