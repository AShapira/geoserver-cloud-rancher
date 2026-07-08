#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

duration="30s"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="$2"; shift ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config
kube_env
kubectl="$(kubectl_bin)"
reports="$REPO_ROOT/reports"
mkdir -p "$reports"
stamp="$(date +%Y%m%d-%H%M%S)"
report_path="$reports/tuning-${stamp}.md"
k6_image="$(harbor_runtime_image "$K6_IMAGE")"
script_path="$REPO_ROOT/tests/k6/protocol.js"

"$kubectl" -n "$GEOSERVER_NAMESPACE" create configmap k6-protocol --from-file=protocol.js="$script_path" --dry-run=client -o yaml | "$kubectl" apply -f -
cat > "$report_path" <<EOF
# GeoServer Cloud tuning report

Generated: $(date -Iseconds)

| VUs | Result | Log |
| ---: | --- | --- |
EOF
for vus in 1 5 20; do
  job="k6-${vus}-${stamp,,}"
  cat <<EOF | "$kubectl" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${GEOSERVER_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: harbor-credentials
      containers:
        - name: k6
          image: ${k6_image}
          args: ["run", "/scripts/protocol.js"]
          env:
            - name: VUS
              value: "${vus}"
            - name: DURATION
              value: "${duration}"
            - name: BASE_URL
              value: http://gscloud-gsc-gateway.gscloud.svc.cluster.local:8080/geoserver-cloud
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: k6-protocol
EOF
  if "$kubectl" -n "$GEOSERVER_NAMESPACE" wait --for=condition=complete "job/$job" --timeout=300s; then
    status=completed
  else
    status=failed
  fi
  log_path="$reports/${job}.log"
  "$kubectl" -n "$GEOSERVER_NAMESPACE" logs "job/$job" > "$log_path" || true
  printf '| %s | %s | `%s` |\n' "$vus" "$status" "$(basename "$log_path")" >> "$report_path"
done
echo "Tuning report: $report_path"
