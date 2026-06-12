# QGIS browser desktop image

This image adds QGIS Desktop to the pinned Kasm Ubuntu Noble core image. KasmVNC exposes the desktop to a browser while QGIS is preconfigured at startup with the internal GeoServer Cloud WMS/WFS endpoints and the PostGIS database connection.

The image is built and pushed to JCR by `scripts/Prepare-Online.ps1`; it is not pulled directly by the air-gapped cluster.
