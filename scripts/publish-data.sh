#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/publishing.sh"

manifest=""
source_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest="$2"; shift ;;
    --source) source_file="$2"; shift ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[[ -f "$manifest" ]] || die "Manifest not found: $manifest"
[[ -f "$source_file" ]] || die "Source not found: $source_file"

load_config
kube_env
kubectl="$(kubectl_bin)"
size="$(stat -c '%s' "$source_file")"
(( size <= 2147483648 )) || die "The POC publishing workflow accepts source files up to 2 GB."
ext=".${source_file##*.}"
case "${ext,,}" in .gpkg|.geojson|.json|.tif|.tiff) ;; *) die "Unsupported source extension: $ext" ;; esac

run_id="$(openssl rand -hex 6)"
stager="publish-stage-${run_id}"
job_name="publish-data-${run_id}"
request_dir="/data/publishing/requests/${run_id}"
pod_path="$STATE_DIR/${stager}.json"

jq -n --arg name "$stager" --arg ns "$GEOSERVER_NAMESPACE" --arg image "$(publisher_image)" '{
  apiVersion:"v1", kind:"Pod",
  metadata:{name:$name,namespace:$ns,labels:{"app.kubernetes.io/name":"gscloud-publish-stager"}},
  spec:{
    restartPolicy:"Never",
    imagePullSecrets:[{name:"harbor-credentials"}],
    securityContext:{fsGroup:1000},
    containers:[{name:"stager",image:$image,command:["sh","-c","sleep 3600"],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},volumeMounts:[{name:"geodata",mountPath:"/data"}]}],
    volumes:[{name:"geodata",persistentVolumeClaim:{claimName:"gscloud-geodata"}}]
  }
}' > "$pod_path"

trap '"$kubectl" -n "$GEOSERVER_NAMESPACE" delete pod "$stager" --wait=false >/dev/null 2>&1 || true' EXIT
run "$kubectl" apply -f "$pod_path"
run "$kubectl" -n "$GEOSERVER_NAMESPACE" wait --for=condition=Ready "pod/$stager" --timeout=5m
run "$kubectl" -n "$GEOSERVER_NAMESPACE" exec "$stager" -- mkdir -p "$request_dir"
run "$kubectl" -n "$GEOSERVER_NAMESPACE" cp "$(realpath "$manifest")" "${stager}:${request_dir}/manifest.yaml"
run "$kubectl" -n "$GEOSERVER_NAMESPACE" cp "$(realpath "$source_file")" "${stager}:${request_dir}/source${ext,,}"
trap - EXIT
"$kubectl" -n "$GEOSERVER_NAMESPACE" delete pod "$stager" --wait=false >/dev/null || true

run_publisher_job "$job_name" publish --manifest "${request_dir}/manifest.yaml" --source "${request_dir}/source${ext,,}"
echo "Published source through Job $job_name"
