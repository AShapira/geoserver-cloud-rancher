#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

publisher_image() {
  local_runtime_image "$PUBLISHER_IMAGE_NAME" "$PUBLISHER_IMAGE_TAG"
}

publisher_env_json() {
  jq -n --arg maps "$MAPS_HOSTNAME" '[
    {"name":"GEOSERVER_URL","value":"http://gscloud-gsc-gateway:8080/geoserver-cloud"},
    {"name":"GEOSERVER_USER","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"geoserver-admin-username"}}},
    {"name":"GEOSERVER_PASSWORD","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"geoserver-admin-password"}}},
    {"name":"PUBLIC_BASE_URL","value":("https://" + $maps)},
    {"name":"POSTGIS_HOST","value":"platform-platform-infra-postgis.platform-infra.svc.cluster.local"},
    {"name":"POSTGIS_PORT","value":"5432"},
    {"name":"POSTGIS_DATABASE","value":"gisdata"},
    {"name":"POSTGIS_USER","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"pgconfig-username"}}},
    {"name":"POSTGIS_PASSWORD","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"pgconfig-password"}}},
    {"name":"PGSTAC_HOST","value":"platform-platform-infra-pgstac.platform-infra.svc.cluster.local"},
    {"name":"PGSTAC_PORT","value":"5432"},
    {"name":"PGSTAC_DATABASE","value":"stac"},
    {"name":"PGSTAC_USER","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"stac-username"}}},
    {"name":"PGSTAC_PASSWORD","valueFrom":{"secretKeyRef":{"name":"gscloud-runtime","key":"stac-password"}}}
  ]'
}

publisher_job_json() {
  local name="$1"
  shift
  jq -n \
    --arg name "$name" \
    --arg namespace "$GEOSERVER_NAMESPACE" \
    --arg image "$(publisher_image)" \
    --argjson args "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    --argjson env "$(publisher_env_json)" '{
      apiVersion:"batch/v1",
      kind:"Job",
      metadata:{name:$name,namespace:$namespace,labels:{"app.kubernetes.io/name":"gscloud-publisher"}},
      spec:{
        backoffLimit:0,
        ttlSecondsAfterFinished:86400,
        template:{
          metadata:{labels:{"app.kubernetes.io/name":"gscloud-publisher"}},
          spec:{
            restartPolicy:"Never",
            imagePullSecrets:[{name:"harbor-credentials"}],
            securityContext:{fsGroup:1000},
            containers:[{
              name:"publisher",
              image:$image,
              imagePullPolicy:"IfNotPresent",
              args:$args,
              env:$env,
              securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},
              volumeMounts:[{name:"geodata",mountPath:"/data"}]
            }],
            volumes:[{name:"geodata",persistentVolumeClaim:{claimName:"gscloud-geodata"}}]
          }
        }
      }
    }'
}

run_publisher_job() {
  local name="$1"
  shift
  local path="$STATE_DIR/${name}.json"
  publisher_job_json "$name" "$@" > "$path"
  kubectl apply -f "$path"
  if kubectl -n "$GEOSERVER_NAMESPACE" wait --for=condition=complete "job/$name" --timeout=30m; then
    kubectl -n "$GEOSERVER_NAMESPACE" logs "job/$name"
  else
    kubectl -n "$GEOSERVER_NAMESPACE" logs "job/$name" || true
    die "Publisher Job failed or timed out: $name"
  fi
}
