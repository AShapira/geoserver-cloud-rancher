#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
kube_env
kubectl="$(kubectl_bin)"

node_name="$("$kubectl" get nodes -o jsonpath='{.items[0].metadata.name}')"
storage_root="${RKE2_LOCAL_STORAGE_ROOT:-/var/lib/rancher/rke2/local-storage/geoserver-cloud-rancher}"

run_sudo mkdir -p \
  "$storage_root/postgis" \
  "$storage_root/rabbitmq" \
  "$storage_root/pgstac" \
  "$storage_root/pgadmin" \
  "$storage_root/geodata" \
  "$storage_root/gwc-cache" \
  "$storage_root/qgis-profile"
run_sudo chown -R 999:999 "$storage_root/postgis" "$storage_root/rabbitmq" "$storage_root/pgstac"
run_sudo chown -R 5050:0 "$storage_root/pgadmin"
run_sudo chown -R 1000:1000 "$storage_root/geodata" "$storage_root/gwc-cache" "$storage_root/qgis-profile"
run_sudo chmod 0770 \
  "$storage_root/postgis" \
  "$storage_root/rabbitmq" \
  "$storage_root/pgstac" \
  "$storage_root/pgadmin" \
  "$storage_root/geodata" \
  "$storage_root/gwc-cache" \
  "$storage_root/qgis-profile"

"$kubectl" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: platform-postgis-local
spec:
  capacity:
    storage: 8Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${PLATFORM_NAMESPACE}
    name: data-platform-platform-infra-postgis-0
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/postgis
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: platform-rabbitmq-local
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${PLATFORM_NAMESPACE}
    name: data-platform-platform-infra-rabbitmq-0
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/rabbitmq
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: platform-pgstac-local
spec:
  capacity:
    storage: 8Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${PLATFORM_NAMESPACE}
    name: data-platform-platform-infra-pgstac-0
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/pgstac
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: platform-pgadmin-local
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${PLATFORM_NAMESPACE}
    name: platform-platform-infra-pgadmin
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/pgadmin
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gscloud-geodata-local
spec:
  capacity:
    storage: 8Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${GEOSERVER_NAMESPACE}
    name: gscloud-geodata
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/geodata
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gscloud-gwc-cache-local
spec:
  capacity:
    storage: 4Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${GEOSERVER_NAMESPACE}
    name: gscloud-gwc-cache
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/gwc-cache
    type: Directory
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gscloud-qgis-profile-local
spec:
  capacity:
    storage: 4Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  claimRef:
    namespace: ${GEOSERVER_NAMESPACE}
    name: gscloud-qgis-profile
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node_name}
  hostPath:
    path: ${storage_root}/qgis-profile
    type: Directory
EOF

echo "Prepared RKE2 local PersistentVolumes under ${storage_root}"
