# GeoServer Cloud Air-Gap Rancher Simulation

This repository builds a local Rancher-managed K3s environment whose runtime can reach only a local JFrog Container Registry (JCR). It deploys GeoServer Cloud `3.0.0-RC` with PostgreSQL/PGConfig, external RabbitMQ, persistent GeoWebCache storage, an offline OpenLayers viewer, browser-accessible QGIS Desktop, and pgAdmin.

## Quick start

Run PowerShell as the current Windows user from the repository root:

```powershell
.\scripts\Install-Tools.ps1
.\scripts\Initialize-State.ps1
.\scripts\Prepare-Online.ps1
.\scripts\New-Cluster.ps1
.\scripts\Install-Rancher.ps1
.\scripts\Deploy.ps1
.\scripts\Enter-AirGap.ps1
.\scripts\Validate.ps1 -Deep
```

Endpoints:

- Rancher: `https://rancher.localhost`
- Viewer: `https://maps.localhost`
- GeoServer Cloud: `https://maps.localhost/geoserver-cloud/`
- QGIS Desktop: `https://qgis.localhost` (user `kasm_user`; password in `.state/config.env`)
- pgAdmin: `https://pgadmin.localhost` (user `admin@example.com`; password in `.state/config.env`)
- JCR: `https://jcr.localhost:5443`

JCR also exposes `http://127.0.0.1:5080` only on Windows loopback for first-run administration. Registry and Kubernetes traffic remains TLS-only.

Generated passwords are stored in `.state/config.env`, which is excluded from Git. The local development CA is installed in the current user's Windows trust store by `Initialize-State.ps1` unless `-SkipTrust` is used.

QGIS is a single persistent desktop session streamed by the open-source KasmVNC component. It is preconfigured for the internal GeoServer WMS/WFS endpoints and PostGIS database and shares the `/data` PVC with the GeoServer Cloud services.

pgAdmin is preconfigured with a `PostGIS POC` server using the generated PostgreSQL superuser credentials. Its settings and user files persist on a dedicated PVC.

See [operations.md](docs/operations.md) for lifecycle commands and [architecture.md](docs/architecture.md) for the network and service design.
