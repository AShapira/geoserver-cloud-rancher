# Tuning

## Current Replica Baseline

The default chart values run WMS and WFS with two replicas each:

```yaml
geoservercloud:
  geoserver:
    services:
      wms:
        replicaCount: 2
      wfs:
        replicaCount: 2
```

Verify live state with:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
.tools/kubectl -n gscloud get deploy gscloud-gsc-wms gscloud-gsc-wfs
.tools/kubectl -n gscloud get pods -l app.kubernetes.io/component=wms -o wide
.tools/kubectl -n gscloud get pods -l app.kubernetes.io/component=wfs -o wide
```

## Scaling A Service

For a persistent chart-level change, edit `charts/geoserver-cloud-sim/values.yaml` and redeploy:

```bash
./scripts/prepare-online.sh --skip-mirror
./scripts/deploy.sh
```

For a temporary runtime experiment:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
.tools/kubectl -n gscloud scale deployment gscloud-gsc-wms --replicas=3
.tools/kubectl -n gscloud rollout status deployment gscloud-gsc-wms --timeout=300s
```

Temporary `kubectl scale` changes are overwritten by the next Helm deployment.

## HPA

`deploy.sh --enable-wms-hpa` passes `geoservercloud.geoserver.services.wms.hpa.enabled=true` to Helm. Use it only after confirming the dependency chart values and resource requests match the target behavior.

```bash
./scripts/deploy.sh --enable-wms-hpa
```

If you maintain an extra `values-tuning.yaml`, `deploy.sh --tuned` will include it. The baseline repository does not require that file for the current WMS/WFS two-replica setup.

## Load Testing

`run-loadtests.sh` runs k6 profiles and writes Markdown reports under `reports/`.

Before changing requests, limits, connection pools, or replica counts, record:

- p95 latency and failure rate.
- WMS/WFS pod CPU and memory.
- PostgreSQL connection count.
- RabbitMQ queue depth.
- GeoWebCache hit/miss behavior.

Useful commands:

```bash
./scripts/run-loadtests.sh
.tools/kubectl -n gscloud top pods
.tools/kubectl -n platform-infra top pods
.tools/kubectl -n platform-infra exec statefulset/platform-platform-infra-postgis -- psql -U postgres -tAc "select count(*) from pg_stat_activity;"
```

The simulation is single-node. Adding replicas improves concurrency only within the CPU, memory, disk, and network limits of that node.
