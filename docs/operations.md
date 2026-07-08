# Operations

## Lifecycle

| Task | Command |
| --- | --- |
| Install pinned local tools | `./scripts/install-tools.sh` |
| Generate secrets and certificates | `./scripts/initialize-state.sh` |
| Start Harbor and prepare artifacts | `./scripts/prepare-online.sh` |
| Rebuild local app images and charts without remirroring upstream images | `./scripts/prepare-online.sh --skip-mirror` |
| Force remirroring upstream images | `./scripts/prepare-online.sh --force-mirror` |
| Install or reconcile native RKE2 | `./scripts/install-rke2.sh` |
| Deploy platform and app Helm releases | `./scripts/deploy.sh` |
| Install Rancher UI, optional | `./scripts/install-rancher.sh` |
| Register Harbor OCI charts in Rancher Apps, optional | `./scripts/register-rancher-catalog.sh` |
| Block cluster pod egress | `./scripts/enter-airgap.sh` |
| Temporarily restore pod egress | `./scripts/exit-airgap.sh` |
| Run static checks | `./scripts/test-static.sh` |
| Validate runtime protocols and sample data | `./scripts/validate.sh --deep` |
| Exercise restarts and persistence | `./scripts/test-restart.sh` |
| Run k6 profiles | `./scripts/run-loadtests.sh` |
| Publish a dataset release | `./scripts/publish-data.sh --manifest <yaml> --source <file>` |
| Fully unpublish a release | `./scripts/unpublish-data.sh --collection-id <id> --version <version>` |
| Stop the environment | `./scripts/teardown.sh` |
| Destroy generated state | `./scripts/teardown.sh --purge-data` |

Harbor uses the generated administrator password from `.state/config.env`. The bootstrap flow creates separate Harbor projects for images and charts and uses Harbor OCI registry support for Helm charts.

## Standard Deployment

For a new RHEL10 host:

```bash
./scripts/install-tools.sh
./scripts/initialize-state.sh
./scripts/prepare-online.sh
./scripts/install-rke2.sh
./scripts/deploy.sh
```

After code-only changes to charts or local images:

```bash
./scripts/prepare-online.sh --skip-mirror
./scripts/deploy.sh
```

After version changes in `versions.lock.yaml` or `scripts/common.sh`:

```bash
./scripts/prepare-online.sh --force-mirror
./scripts/deploy.sh
```

`deploy.sh` prepares static local PersistentVolumes, creates namespaces and image pull Secrets, deploys the `platform` and `gscloud` Helm releases from Harbor, and registers Rancher catalog repositories only when Rancher CRDs exist.

## Current Releases

The normal app deployment creates these Helm releases:

| Release | Namespace | Chart | Purpose |
| --- | --- | --- | --- |
| `platform` | `platform-infra` | `platform-infra-0.3.0` | PostGIS, RabbitMQ, PgSTAC, pgAdmin |
| `gscloud` | `gscloud` | `geoserver-cloud-sim-0.3.0` | GeoServer Cloud, viewer, STAC, QGIS, publisher |

RKE2 system charts are installed in `kube-system`. In this installation, ingress is Traefik.

Useful status commands:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
.tools/helm list -A
.tools/kubectl get nodes -o wide
.tools/kubectl get pods -A -o wide
.tools/kubectl -n gscloud get deploy gscloud-gsc-wms gscloud-gsc-wfs
```

WMS and WFS should report `2/2` ready.

## Endpoint Checks

Use the generated CA from `.state/certs/ca.crt` or `curl -k` for quick local checks:

```bash
curl -k -I https://maps.localhost/
curl -k -I https://maps.localhost/stac/
curl -k https://maps.localhost/api/stac/collections
curl -k -I https://maps.localhost/geoserver-cloud/wms
curl -k -I https://maps.localhost/geoserver-cloud/wfs
curl -k -I https://qgis.localhost/
curl -k --http1.1 https://pgadmin.localhost/misc/ping
curl -k -I https://harbor.airgap.local:5443/
```

Expected results:

- Viewer and STAC Browser return `200`.
- STAC collections include `demo-places` and `demo-raster` after bootstrap completes.
- WMS and WFS return `200`.
- QGIS returns `401 Basic realm="Websockify"` before login.
- pgAdmin `/misc/ping` returns `PING`.
- Harbor returns `200`.

`validate.sh --deep` performs a broader protocol check and writes artifacts to `.state/validation/`. It currently checks Rancher too; install Rancher before running it, or use the endpoint checks above when running the app stack without Rancher.

## QGIS Desktop

Open `https://qgis.localhost` and sign in as `kasm_user`. The generated password is `QGIS_PASSWORD` in `.state/config.env`.

The deployment provides one shared browser desktop rather than isolated per-user sessions. Its persistent profile is mounted at `/home/kasm-user`, and geodata shared with GeoServer is mounted at `/data`. QGIS starts with saved connections named `GeoServer PostGIS` and `GeoServer Cloud`.

From the QGIS terminal, the REST helper uses the generated GeoServer administrator credentials without printing them:

```bash
geoserver-rest GET about/version.json
geoserver-rest GET workspaces/demo/datastores.json
```

QGIS, KasmVNC, and the Kasm core image source are open source. This deployment does not install the full Kasm Workspaces platform.

## pgAdmin

Open `https://pgadmin.localhost` and sign in with `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_PASSWORD` from `.state/config.env`. The default email is `admin@example.com`.

The `PostGIS POC` server is loaded declaratively and connects to the internal PostGIS service as the generated `postgres` superuser. Its password is copied from a Kubernetes Secret into pgAdmin's private `.pgpass` file; it is not stored in `servers.json`. The connection provides access to the `postgres`, `gscloud_config`, and `gisdata` databases.

pgAdmin configuration and user files persist under `/var/lib/pgadmin` on the pgAdmin PVC. Database data remains on the separate PostGIS PVC.

## STAC Publishing

`DatasetRelease` manifests use the schema in `publishing/dataset-release.schema.json`. Examples for vector and raster releases are under `publishing/examples`.

Publication stages the local file on `gscloud-geodata`, then runs a Kubernetes Job that:

1. Checks the collection/version tombstone and source checksum.
2. Loads vectors into a version-specific PostGIS table or normalizes rasters to COG.
3. Publishes the release through GeoServer WMS/WMTS plus WFS or WCS.
4. Validates an optional existing style; style creation is intentionally out of scope.
5. Upserts the STAC Collection and immutable Item only after GeoServer succeeds.
6. Writes a private receipt used for idempotency, recovery, and unpublish.

Reusing a version with changed content is rejected. Unpublish removes the STAC Item, GeoWebCache and GeoServer resources, database table or raster file, and public asset. The Collection is retained when empty unless collection removal is requested. A tombstone prevents accidental reuse of the removed version.

## Air-Gap Mode

After deployment:

```bash
./scripts/enter-airgap.sh
```

This applies default-deny pod egress NetworkPolicies with private-network exceptions and runs a canary pod that must not reach `https://example.com`.

To remove the policies:

```bash
./scripts/exit-airgap.sh
```

Strict host egress is available but opt-in:

```bash
./scripts/enter-airgap.sh --strict-host-egress
```

Use strict host egress only when you are ready to block non-private outbound traffic from the RHEL host itself.

## Recovery Order

If the host restarts or services are stopped:

1. Start Podman socket: `sudo systemctl enable --now podman.socket`.
2. Start Harbor: `./scripts/start-harbor.sh`.
3. Start RKE2: `sudo systemctl start rke2-server`.
4. Wait for the node: `KUBECONFIG=/etc/rancher/rke2/rke2.yaml .tools/kubectl wait --for=condition=Ready node --all --timeout=300s`.
5. Check pods: `KUBECONFIG=/etc/rancher/rke2/rke2.yaml .tools/kubectl get pods -A`.
6. Run endpoint checks or `./scripts/validate.sh --deep` when Rancher is installed.

## Updating Pinned Components

Update `versions.lock.yaml` and the matching constants in `scripts/common.sh`, then run:

```bash
./scripts/prepare-online.sh --force-mirror
./scripts/deploy.sh
./scripts/test-static.sh
```

Rendered runtime charts must not contain public image references. `test-static.sh` checks this by rendering both charts and rejecting images outside Harbor.
