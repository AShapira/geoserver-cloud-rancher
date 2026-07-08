#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/publishing.sh"

collection=""
version=""
remove_collection=0
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --collection-id) collection="$2"; shift ;;
    --version) version="$2"; shift ;;
    --remove-collection) remove_collection=1 ;;
    --force) force=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[[ -n "$collection" && -n "$version" ]] || die "Usage: $0 --collection-id <id> --version <version> [--remove-collection] [--force]"

if [[ "$force" -eq 0 ]]; then
  read -r -p "Type ${collection}/${version} to confirm full unpublish: " confirmation
  [[ "$confirmation" == "${collection}/${version}" ]] || die "Unpublish cancelled."
fi

load_config
kube_env
run_id="$(openssl rand -hex 6)"
args=(unpublish --collection "$collection" --version "$version")
[[ "$remove_collection" -eq 1 ]] && args+=(--remove-collection)
run_publisher_job "unpublish-data-${run_id}" "${args[@]}"
echo "Unpublished ${collection}/${version}"
