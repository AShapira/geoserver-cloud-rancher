#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

force=0
skip_trust=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1 ;;
    --skip-trust) skip_trust=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

mkdir -p "$STATE_DIR/certs"
read_defaults
if [[ -f "$CONFIG_PATH" && "$force" -eq 0 ]]; then
  load_config
fi

CLUSTER_NAME="${CLUSTER_NAME:-gscloud-rke2}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.airgap.local}"
HARBOR_PORT="${HARBOR_PORT:-5443}"
HARBOR_EXTERNAL_HOST="${HARBOR_EXTERNAL_HOST:-${HARBOR_HOSTNAME}:${HARBOR_PORT}}"
HARBOR_INTERNAL_HOST="${HARBOR_INTERNAL_HOST:-$(host_primary_ip):${HARBOR_PORT}}"
HARBOR_IMAGE_PROJECT="${HARBOR_IMAGE_PROJECT:-airgap}"
HARBOR_CHART_PROJECT="${HARBOR_CHART_PROJECT:-charts}"
HARBOR_ADMIN_USERNAME="${HARBOR_ADMIN_USERNAME:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-$(random_secret 24)}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:-$(random_secret 24)}"
RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:-$(random_secret 24)}"
RABBITMQ_USERNAME="${RABBITMQ_USERNAME:-geoserver}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-$(random_secret 24)}"
RABBITMQ_ERLANG_COOKIE="${RABBITMQ_ERLANG_COOKIE:-$(random_secret 32)}"
POSTGRES_SUPER_USERNAME="${POSTGRES_SUPER_USERNAME:-postgres}"
POSTGRES_SUPER_PASSWORD="${POSTGRES_SUPER_PASSWORD:-$(random_secret 24)}"
GEOSERVER_DB_USERNAME="${GEOSERVER_DB_USERNAME:-geoserver}"
GEOSERVER_DB_PASSWORD="${GEOSERVER_DB_PASSWORD:-$(random_secret 24)}"
GEOSERVER_ADMIN_USERNAME="${GEOSERVER_ADMIN_USERNAME:-admin}"
GEOSERVER_ADMIN_PASSWORD="${GEOSERVER_ADMIN_PASSWORD:-$(random_secret 24)}"
STAC_DB_USERNAME="${STAC_DB_USERNAME:-stac}"
STAC_DB_PASSWORD="${STAC_DB_PASSWORD:-$(random_secret 24)}"
QGIS_PASSWORD="${QGIS_PASSWORD:-$(random_secret 18)}"
PGADMIN_PASSWORD="${PGADMIN_PASSWORD:-$(random_secret 18)}"
STATE_DIR="$STATE_DIR"

write_config

ca_key="$STATE_DIR/certs/ca.key"
ca_crt="$STATE_DIR/certs/ca.crt"
server_key="$STATE_DIR/certs/server.key"
server_csr="$STATE_DIR/certs/server.csr"
server_crt="$STATE_DIR/certs/server.crt"
openssl_cnf="$STATE_DIR/certs/openssl.cnf"
harbor_ip="$(normalize_host_without_port "$HARBOR_INTERNAL_HOST")"

cat > "$openssl_cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
req_extensions = req_ext

[dn]
CN = GeoServer Airgap Local Endpoints
O = GeoServer Airgap Simulation

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${RANCHER_HOSTNAME}
DNS.2 = ${MAPS_HOSTNAME}
DNS.3 = ${QGIS_HOSTNAME}
DNS.4 = ${PGADMIN_HOSTNAME}
DNS.5 = ${HARBOR_HOSTNAME}
DNS.6 = localhost
IP.1 = 127.0.0.1
IP.2 = ${harbor_ip}
EOF

if [[ "$force" -eq 1 || ! -f "$ca_crt" || ! -f "$ca_key" ]]; then
  run openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -subj '/CN=GeoServer Airgap Development CA/O=GeoServer Airgap Simulation' \
    -keyout "$ca_key" -out "$ca_crt"
fi

if [[ "$force" -eq 1 || ! -f "$server_crt" || ! -f "$server_key" ]]; then
  run openssl req -new -newkey rsa:2048 -nodes -keyout "$server_key" -out "$server_csr" -config "$openssl_cnf"
  run openssl x509 -req -in "$server_csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
    -out "$server_crt" -days 825 -sha256 -extensions req_ext -extfile "$openssl_cnf"
fi

if [[ "$skip_trust" -eq 0 && -d /etc/pki/ca-trust/source/anchors ]]; then
  run_sudo cp "$ca_crt" /etc/pki/ca-trust/source/anchors/geoserver-airgap-ca.crt
  run_sudo update-ca-trust
fi

if [[ -n "${HARBOR_EXTERNAL_HOST:-}" ]]; then
  certs_dir="/etc/containers/certs.d/${HARBOR_EXTERNAL_HOST}"
  run_sudo mkdir -p "$certs_dir"
  run_sudo cp "$ca_crt" "$certs_dir/ca.crt"
fi

if ! grep -Eq "[[:space:]]${HARBOR_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
  printf '127.0.0.1 %s\n' "$HARBOR_HOSTNAME" | run_sudo tee -a /etc/hosts >/dev/null
fi

echo "Generated state: $CONFIG_PATH"
echo "Development CA: $ca_crt"
