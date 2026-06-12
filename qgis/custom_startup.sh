#!/usr/bin/env bash
set -euo pipefail

/usr/bin/desktop_ready

mkdir -p "$HOME/Desktop" /data

cat >"$HOME/Desktop/GeoServer REST API.txt" <<EOF
GeoServer Web and REST base URL:
${GEOSERVER_INTERNAL_URL}

Examples:
  geoserver-rest GET about/version.json
  geoserver-rest GET workspaces.json
  geoserver-rest GET workspaces/demo/datastores.json
EOF

cat >"$HOME/Desktop/Shared data directory.txt" <<EOF
Shared GeoServer and QGIS data directory: /data

Files created here persist on the geodata PVC and are visible to the
GeoServer Cloud service pods.
EOF

/usr/bin/qgis --code /opt/qgis/bootstrap.py >/tmp/qgis.log 2>&1 &
