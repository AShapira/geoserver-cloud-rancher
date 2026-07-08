#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
kube_env
kubectl="$(kubectl_bin)"
qgis_pod="$("$kubectl" -n "$GEOSERVER_NAMESPACE" get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}')"
token="restart-$(date +%Y%m%d%H%M%S)"
run "$kubectl" -n "$GEOSERVER_NAMESPACE" exec "$qgis_pod" -- sh -c "printf %s '$token' > /data/restart-persistence.txt"
pgadmin_pod="$("$kubectl" -n "$PLATFORM_NAMESPACE" get pod -l app.kubernetes.io/component=pgadmin -o jsonpath='{.items[0].metadata.name}')"
rabbit_pod="$("$kubectl" -n "$PLATFORM_NAMESPACE" get pod -l app.kubernetes.io/component=rabbitmq -o jsonpath='{.items[0].metadata.name}')"
postgis_pod="$("$kubectl" -n "$PLATFORM_NAMESPACE" get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}')"
run "$kubectl" -n "$PLATFORM_NAMESPACE" delete pod "$rabbit_pod" "$postgis_pod" "$pgadmin_pod"
run "$kubectl" -n "$PLATFORM_NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/component=rabbitmq --timeout=300s
run "$kubectl" -n "$PLATFORM_NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/component=postgis --timeout=300s
run "$kubectl" -n "$PLATFORM_NAMESPACE" rollout status deployment -l app.kubernetes.io/component=pgadmin --timeout=300s
for deployment in $("${kubectl}" -n "$GEOSERVER_NAMESPACE" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  run "$kubectl" -n "$GEOSERVER_NAMESPACE" rollout restart deployment "$deployment"
  run "$kubectl" -n "$GEOSERVER_NAMESPACE" rollout status deployment "$deployment" --timeout=300s
done
qgis_pod="$("$kubectl" -n "$GEOSERVER_NAMESPACE" get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}')"
observed="$("$kubectl" -n "$GEOSERVER_NAMESPACE" exec "$qgis_pod" -- cat /data/restart-persistence.txt)"
[[ "$observed" == "$token" ]] || die "Shared data persistence token did not survive restart."
echo "Restart and persistence checks passed."
