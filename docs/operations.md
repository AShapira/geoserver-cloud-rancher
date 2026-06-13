# Operations

## Lifecycle

| Task | Command |
| --- | --- |
| Install pinned local tools | `.\scripts\Install-Tools.ps1` |
| Generate secrets and certificates | `.\scripts\Initialize-State.ps1` |
| Start/configure JCR and mirror artifacts | `.\scripts\Prepare-Online.ps1` |
| Create isolated k3d cluster | `.\scripts\New-Cluster.ps1` |
| Install Rancher | `.\scripts\Install-Rancher.ps1` |
| Register OCI catalog and deploy applications | `.\scripts\Deploy.ps1` |
| Disconnect JCR bootstrap egress and block cluster egress | `.\scripts\Enter-AirGap.ps1` |
| Temporarily restore bootstrap egress | `.\scripts\Exit-AirGap.ps1` |
| Validate protocols and propagation | `.\scripts\Validate.ps1 -Deep` |
| Exercise restarts and persistence | `.\scripts\Test-Restart.ps1` |
| Run k6 profiles | `.\scripts\Run-LoadTests.ps1` |
| Publish a dataset release | `.\scripts\Publish-Data.ps1 -Manifest <yaml> -Source <file>` |
| Fully unpublish a release | `.\scripts\Unpublish-Data.ps1 -CollectionId <id> -Version <version>` |
| Stop the environment | `.\scripts\Teardown.ps1` |
| Destroy generated data | `.\scripts\Teardown.ps1 -PurgeData` |

JCR uses the generated administrator password for Basic Auth. JCR Edition blocks the Pro repository and user REST endpoints, so repository bootstrap uses JFrog's supported YAML configuration patch endpoint.

`Prepare-Online.ps1` mirrors the complete image set resolved by this simulation. `-IncludeRancherReleaseImageSet` additionally mirrors Rancher's full release catalog, including images for unrelated downstream Kubernetes variants and optional applications; budget hundreds of gigabytes for that mode.

## QGIS desktop

Open `https://qgis.localhost` and sign in as `kasm_user`. The generated password is the `QGIS_PASSWORD` value in `.state/config.env`.

The deployment provides one shared browser desktop rather than isolated sessions. Its persistent profile is mounted at `/home/kasm-user`, and geodata shared with GeoServer is mounted at `/data`. QGIS starts with saved connections named `GeoServer PostGIS` and `GeoServer Cloud`.

From the QGIS terminal, the REST helper uses the generated GeoServer administrator credentials without printing them:

```bash
geoserver-rest GET about/version.json
geoserver-rest GET workspaces/demo/datastores.json
```

QGIS, KasmVNC, and the Kasm core-image source are open source. This deployment does not install the full Kasm Workspaces platform.

## pgAdmin

Open `https://pgadmin.localhost` and sign in with the `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_PASSWORD` values from `.state/config.env`. The default email is `admin@example.com`.

The `PostGIS POC` server is loaded declaratively and connects to the internal PostGIS service as the generated `postgres` superuser. Its password is copied from a Kubernetes Secret into pgAdmin's private `.pgpass` file; it is not stored in `servers.json`. The connection provides access to the `postgres`, `gscloud_config`, and `gisdata` databases.

pgAdmin configuration and user files persist under `/var/lib/pgadmin`. Backup and restore files created in the UI are therefore retained on the 2 GiB pgAdmin PVC across pod and node restarts. Database data remains on the separate PostGIS PVC.

pgAdmin is open source under the PostgreSQL Licence. Update checks, Gravatar requests, and Postfix are disabled for offline operation.

## STAC publishing

`DatasetRelease` manifests use the schema in `publishing/dataset-release.schema.json`. Examples for vector and raster releases are under `publishing/examples`.

Publication stages the local file on `gscloud-geodata`, then runs a Kubernetes Job that:

1. Checks the collection/version tombstone and source checksum.
2. Loads vectors into a version-specific PostGIS table or normalizes rasters to COG.
3. Publishes the release through GeoServer WMS/WMTS plus WFS or WCS.
4. Validates an optional existing style; style creation is intentionally out of scope.
5. Upserts the STAC Collection and immutable Item only after GeoServer succeeds.
6. Writes a private receipt used for idempotency, recovery, and unpublish.

Reusing a version with changed content is rejected. Unpublish removes the STAC Item, GeoWebCache and GeoServer resources, database table or raster file, and public asset. The Collection is retained when empty unless `-RemoveCollection` is passed. A tombstone prevents accidental reuse of the removed version.

The custom STAC Browser is built with `/stac/` as its path prefix and an empty basemap configuration. It has no public tile dependency. The STAC API is read-only at the gateway; only Item Search accepts POST.

## Recovery order

1. Start Docker Desktop.
2. Run `Start-Jcr.ps1` and wait for JCR health.
3. Start the k3d cluster if stopped: `k3d cluster start gscloud-airgap`.
4. Run `Validate.ps1`.

## Updating pinned components

Update `versions.lock.yaml` and the corresponding constants in `scripts/Common.ps1`, run `Prepare-Online.ps1 -ForceMirror`, then repeat the isolation and validation tests. Runtime charts must never contain references outside `jcr-proxy:8443/docker-local`.

Changing `QGIS_IMAGE_TAG` requires rebuilding with `Prepare-Online.ps1`. Existing installations can run `Initialize-State.ps1` to add missing QGIS and pgAdmin configuration and regenerate the endpoint certificate with `qgis.localhost` and `pgadmin.localhost` while retaining the existing CA and passwords.
