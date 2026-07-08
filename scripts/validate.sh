#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

deep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep) deep=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config
kube_env
kubectl="$(kubectl_bin)"
ca="$STATE_DIR/certs/ca.crt"
base="https://${MAPS_HOSTNAME}/geoserver-cloud"
auth="${GEOSERVER_ADMIN_USERNAME}:${GEOSERVER_ADMIN_PASSWORD}"
out="$STATE_DIR/validation"
mkdir -p "$out"

deadline=$((SECONDS + 600))
while true; do
  pending="$("$kubectl" get pods --all-namespaces -o json | jq -r --arg p "$PLATFORM_NAMESPACE" --arg g "$GEOSERVER_NAMESPACE" '
    .items[] | select(.metadata.namespace == $p or .metadata.namespace == $g) |
    select(.status.phase != "Succeeded") |
    select(.status.phase == "Failed" or ([.status.containerStatuses[]? | select(.ready != true)] | length > 0)) |
    "\(.metadata.namespace)/\(.metadata.name)"')"
  [[ -z "$pending" ]] && break
  (( SECONDS < deadline )) || die "Pods did not become ready: $pending"
  sleep 5
done

curl_common=(--fail --silent --show-error --cacert "$ca")
run curl "${curl_common[@]}" "https://${RANCHER_HOSTNAME}/ping"
run curl "${curl_common[@]}" "https://${MAPS_HOSTNAME}/healthz"
run curl "${curl_common[@]}" "https://${MAPS_HOSTNAME}/stac/" --output "$out/stac-browser.html"
run curl "${curl_common[@]}" "https://${MAPS_HOSTNAME}/api/stac/" --output "$out/stac-landing.json"
run curl "${curl_common[@]}" "https://${MAPS_HOSTNAME}/api/stac/collections" --output "$out/stac-collections.json"
run curl "${curl_common[@]}" "https://${MAPS_HOSTNAME}/api/stac/search?limit=100" --output "$out/stac-items.json"
run curl "${curl_common[@]}" --user "kasm_user:${QGIS_PASSWORD}" "https://${QGIS_HOSTNAME}/" --output "$out/qgis-desktop.html"
run curl "${curl_common[@]}" "https://${PGADMIN_HOSTNAME}/misc/ping"
run curl "${curl_common[@]}" "$base/wms?service=WMS&version=1.3.0&request=GetCapabilities" --output "$out/wms-capabilities.xml"
run curl "${curl_common[@]}" "$base/wms?service=WMS&version=1.3.0&request=GetMap&layers=demo:demo_places_1_0_0&styles=&crs=EPSG:4326&bbox=34,31,36,33&width=512&height=512&format=image/png" --output "$out/wms-map.png"
run curl "${curl_common[@]}" "$base/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=demo:demo_places_1_0_0&outputFormat=application%2Fjson" --output "$out/wfs-features.json"
run curl "${curl_common[@]}" "$base/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities" --output "$out/wmts-capabilities.xml"
run curl "${curl_common[@]}" "$base/wcs?service=WCS&version=2.0.1&request=GetCapabilities" --output "$out/wcs-capabilities.xml"

[[ "$(jq '.features | length' "$out/wfs-features.json")" == "3" ]] || die "Expected 3 WFS features."
grep -q 'demo:demo_places_1_0_0' "$out/wmts-capabilities.xml" || die "WMTS capabilities do not advertise vector demo release."
grep -q 'demo:demo_raster_1_0_0' "$out/wmts-capabilities.xml" || die "WMTS capabilities do not advertise raster demo release."
grep -q 'demo__demo_raster_1_0_0' "$out/wcs-capabilities.xml" || die "WCS capabilities do not advertise raster release."

postgis_pod="$("$kubectl" -n "$PLATFORM_NAMESPACE" get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}')"
run "$kubectl" -n "$PLATFORM_NAMESPACE" exec "$postgis_pod" -- psql -U postgres -d gisdata -tAc 'SELECT count(*) FROM demo_places_1_0_0;'
qgis_pod="$("$kubectl" -n "$GEOSERVER_NAMESPACE" get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}')"
run "$kubectl" -n "$GEOSERVER_NAMESPACE" exec "$qgis_pod" -- qgis --version
run "$kubectl" -n "$GEOSERVER_NAMESPACE" exec "$qgis_pod" -- geoserver-rest GET about/version.json

if [[ "$deep" -eq 1 ]]; then
  wms_deployment="$("$kubectl" -n "$GEOSERVER_NAMESPACE" get deployment -l app.kubernetes.io/component=wms -o jsonpath='{.items[0].metadata.name}')"
  run "$kubectl" -n "$GEOSERVER_NAMESPACE" scale deployment "$wms_deployment" --replicas=2
  run "$kubectl" -n "$GEOSERVER_NAMESPACE" rollout status deployment "$wms_deployment" --timeout=300s
fi
echo "Validation artifacts: $out"
