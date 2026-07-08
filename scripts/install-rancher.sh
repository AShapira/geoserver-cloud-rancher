#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
kube_env
helm="$(helm_bin)"
kubectl="$(kubectl_bin)"
chart="$STATE_DIR/rancher-${RANCHER_VERSION}.tgz"
[[ -f "$chart" ]] || die "Rancher chart is missing. Run ./scripts/prepare-online.sh first."

run "$kubectl" create namespace "$RANCHER_NAMESPACE" --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$RANCHER_NAMESPACE" create secret docker-registry harbor-credentials \
  --docker-server="$(harbor_runtime_host)" --docker-username="$HARBOR_ADMIN_USERNAME" --docker-password="$HARBOR_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$RANCHER_NAMESPACE" create secret tls tls-rancher-ingress \
  --cert="$STATE_DIR/certs/server.crt" --key="$STATE_DIR/certs/server.key" --dry-run=client -o yaml | "$kubectl" apply -f -
run "$kubectl" -n "$RANCHER_NAMESPACE" create secret generic tls-ca \
  --from-file=cacerts.pem="$STATE_DIR/certs/ca.crt" --dry-run=client -o yaml | "$kubectl" apply -f -

run "$helm" upgrade --install rancher "$chart" \
  --namespace "$RANCHER_NAMESPACE" \
  --set-string "hostname=$RANCHER_HOSTNAME" \
  --set-string "bootstrapPassword=$RANCHER_BOOTSTRAP_PASSWORD" \
  --set replicas=1 \
  --set-string "systemDefaultRegistry=$(harbor_runtime_host)/${HARBOR_IMAGE_PROJECT}" \
  --set ingress.tls.source=secret \
  --set privateCA=true \
  --set useBundledSystemChart=true \
  --set imagePullSecrets[0].name=harbor-credentials \
  --set resources.requests.cpu=250m \
  --set resources.requests.memory=512Mi \
  --set resources.limits.cpu=2 \
  --set resources.limits.memory=2Gi \
  --wait --timeout 15m
run "$kubectl" -n "$RANCHER_NAMESPACE" rollout status deployment/rancher --timeout=600s
echo "Rancher is available at https://${RANCHER_HOSTNAME}"
