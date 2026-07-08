#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
kube_env
kubectl="$(kubectl_bin)"
ca_bundle="$(base64 -w0 "$STATE_DIR/certs/ca.crt")"

if ! "$kubectl" get crd clusterrepos.catalog.cattle.io >/dev/null 2>&1; then
  echo "Rancher catalog CRD is not installed; skipping Rancher Apps repository registration."
  exit 0
fi

run "$kubectl" create namespace "$RANCHER_NAMESPACE" --dry-run=client -o yaml | "$kubectl" apply -f -

run "$kubectl" -n "$RANCHER_NAMESPACE" create secret generic harbor-helm-credentials \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$HARBOR_ADMIN_USERNAME" \
  --from-literal=password="$HARBOR_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | "$kubectl" apply -f -

for chart in geoserver-cloud-sim platform-infra; do
  cat <<EOF | "$kubectl" apply -f -
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: ${chart}-airgap
spec:
  url: oci://$(harbor_runtime_host)/${HARBOR_CHART_PROJECT}/${chart}
  clientSecret:
    name: harbor-helm-credentials
    namespace: ${RANCHER_NAMESPACE}
  caBundle: ${ca_bundle}
  OCIOptions:
    downloadAllTags: true
EOF
done
echo "Registered Harbor OCI charts in Rancher Apps repositories."
