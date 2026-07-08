# QGIS Browser Desktop Image

This image adds QGIS Desktop to the pinned `kasmweb/core-ubuntu-noble:1.19.0` base image. KasmVNC exposes the desktop in a browser, while startup scripts preconfigure QGIS with:

- An internal GeoServer Cloud WMS/WFS connection.
- A PostGIS connection to the platform PostGIS service.
- The local air-gap CA.
- A `geoserver-rest` helper for authenticated GeoServer REST calls.

The image is built by `scripts/prepare-online.sh` and pushed to Harbor as `gscloud/qgis:0.1.0` under the `airgap` project. RKE2 pulls it from Harbor through the `harbor-credentials` image pull Secret.

The deployed QGIS pod mounts:

- `/home/kasm-user` from the QGIS profile PVC, so QGIS settings and projects survive pod recreation.
- `/data` from the shared geodata PVC, so QGIS can inspect the same staged data used by the publisher and GeoServer Cloud services.

Access the running desktop at `https://qgis.localhost/` with user `kasm_user`. The generated password is `QGIS_PASSWORD` in `.state/config.env`.
