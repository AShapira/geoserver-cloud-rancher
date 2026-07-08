# GeoServer Cloud Air-Gap Stack on RHEL10

This repository builds a local, single-node air-gapped GeoServer Cloud stack for RHEL10. Harbor runs on the host with rootful Podman Compose and acts as the private image and OCI chart registry. The application stack runs as Kubernetes workloads under native RKE2.

The deployed stack includes GeoServer Cloud `3.0.0`, PostGIS/PGConfig, RabbitMQ, persistent GeoWebCache storage, PgSTAC/STAC API, an offline STAC Browser, a STAC-aware OpenLayers viewer, browser-accessible QGIS Desktop, and pgAdmin. WMS and WFS are configured with two replicas each.

Rancher is optional. The application does not require Rancher to run; `install-rancher.sh` is available when you want Rancher UI and Apps catalog integration on top of the same RKE2 cluster.

## Quick Start

Run from the repository root on RHEL10:

```bash
./scripts/install-tools.sh
./scripts/initialize-state.sh
./scripts/prepare-online.sh
./scripts/install-rke2.sh
./scripts/deploy.sh
./scripts/enter-airgap.sh
./scripts/test-static.sh
```

Optional Rancher UI:

```bash
./scripts/install-rancher.sh
./scripts/register-rancher-catalog.sh
```

Runtime validation:

```bash
./scripts/validate.sh --deep
```

`validate.sh` checks Rancher as well as the app endpoints. If Rancher is not installed, use `test-static.sh` plus the endpoint checks in [operations.md](docs/operations.md), or install Rancher before running the full validator.

## Endpoints

| Service | URL | Notes |
| --- | --- | --- |
| Viewer | `https://maps.localhost/` | Main OpenLayers viewer |
| STAC Browser | `https://maps.localhost/stac/` | Offline STAC Browser |
| STAC API | `https://maps.localhost/api/stac/` | Read-only public gateway |
| GeoServer Cloud | `https://maps.localhost/geoserver-cloud/` | Gateway to WMS/WFS/WCS/WMTS/REST/Web UI |
| QGIS Desktop | `https://qgis.localhost/` | User `kasm_user`; password in `.state/config.env` |
| pgAdmin | `https://pgadmin.localhost/` | User from `PGADMIN_DEFAULT_EMAIL`; password in `.state/config.env` |
| Harbor | `https://harbor.airgap.local:5443/` | Admin password in `.state/config.env` |
| Rancher | `https://rancher.localhost/` | Optional |

Harbor also exposes `http://127.0.0.1:5080` for local administration during setup. Runtime registry and Kubernetes traffic use TLS.

## What Runs Where

Host-level Podman Compose:

- Harbor core, portal, registry, registryctl, database, Redis, jobservice, nginx, log, and Trivy adapter.

RKE2 `kube-system` namespace:

- RKE2 control-plane components, Canal, CoreDNS, metrics server, snapshot controller, and Traefik ingress.

RKE2 `platform-infra` namespace:

- PostGIS, RabbitMQ, PgSTAC, pgAdmin, bootstrap/init jobs, Services, PVCs, and NetworkPolicies.

RKE2 `gscloud` namespace:

- GeoServer Cloud gateway, web UI, REST, WMS, WFS, WCS, GWC, viewer, STAC API, STAC Browser, STAC gateway, QGIS desktop, bootstrap publisher job, Services, Ingresses, and PVCs.

## State And Secrets

Generated state is stored under `.state/`, which is excluded from Git. The most important files are:

- `.state/config.env`: generated passwords, hostnames, namespaces, and image names.
- `.state/certs/`: local development CA and endpoint certificates.
- `.state/harbor/`: Harbor installer, configuration, and persistent data.
- `.state/validation/`: validation output artifacts.

`initialize-state.sh` installs the development CA into the RHEL trust store and Podman trust unless `--skip-trust` is used.

## Publishing Data

Publish immutable vector or raster releases from the workstation:

```bash
./scripts/publish-data.sh --manifest publishing/examples/vector-release.yaml --source /data/municipalities.gpkg
./scripts/unpublish-data.sh --collection-id municipal-boundaries --version 2026.06
```

The v1 contract accepts GeoPackage, GeoJSON, GeoTIFF, and COG files up to 2 GB. Vector data is loaded into a version-specific PostGIS table; raster data is normalized to COG. Both are published through GeoServer, registered in STAC, and retained as immutable read-only assets.

See [operations.md](docs/operations.md) for lifecycle commands, [architecture.md](docs/architecture.md) for topology and isolation design, and [tuning.md](docs/tuning.md) for replica and load-test guidance.
