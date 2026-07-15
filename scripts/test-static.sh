#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ -f "$CONFIG_PATH" ]] || "$SCRIPT_DIR/initialize-state.sh" --skip-trust
load_config
helm="$(helm_bin)"
errors=0
while IFS= read -r file; do
  bash -n "$file" || errors=$((errors + 1))
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*.sh' -print)
(( errors == 0 )) || die "Bash syntax errors found."

python3 -m py_compile "$REPO_ROOT/publisher/publisher.py" "$REPO_ROOT/publisher/generate_demo.py"
jq empty "$REPO_ROOT/publishing/dataset-release.schema.json"
if grep -Eq 'https?://' "$REPO_ROOT/stac-browser/basemaps.config.js"; then
  die "STAC Browser basemap configuration contains a remote URL."
fi

pushd "$REPO_ROOT/viewer" >/dev/null
npm ci --ignore-scripts
npm audit --audit-level=high
npm run build
popd >/dev/null

helm_home="$STATE_DIR/helm-static"
export HELM_CONFIG_HOME="$helm_home/config" HELM_CACHE_HOME="$helm_home/cache" HELM_DATA_HOME="$helm_home/data"
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
run "$helm" repo add gscloud https://camptocamp.github.io/helm-geoserver-cloud --force-update
run "$helm" dependency update "$REPO_ROOT/charts/geoserver-cloud-sim"
run "$helm" lint "$REPO_ROOT/charts/platform-infra"
run "$helm" lint "$REPO_ROOT/charts/geoserver-cloud-sim"
rendered="$STATE_DIR/rendered.yaml"
"$helm" template gscloud "$REPO_ROOT/charts/geoserver-cloud-sim" --namespace "$GEOSERVER_NAMESPACE" > "$rendered"
"$helm" template platform "$REPO_ROOT/charts/platform-infra" --namespace "$PLATFORM_NAMESPACE" >> "$rendered"
public_images="$(awk '/^[[:space:]]*image:[[:space:]]*/ {gsub(/["'\'']/, "", $2); print $2}' "$rendered" | grep -Ev '^(harbor\.airgap\.local|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):' || true)"
if [[ -n "$public_images" ]]; then
  echo "$public_images" >&2
  die "Rendered public image references remain."
fi

if [[ -f "$STATE_DIR/harbor/installer/docker-compose.yml" ]]; then
  "$(podman_compose_bin)" -f "$STATE_DIR/harbor/installer/docker-compose.yml" config --quiet
fi
echo "Static checks passed."
