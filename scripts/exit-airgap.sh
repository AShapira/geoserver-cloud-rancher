#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
kube_env
kubectl="$(kubectl_bin)"
for namespace in $("${kubectl}" get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  "$kubectl" -n "$namespace" delete networkpolicy airgap-egress --ignore-not-found >/dev/null
done
run_sudo iptables -D OUTPUT -j AIRGAP_HOST 2>/dev/null || true
run_sudo iptables -F AIRGAP_HOST 2>/dev/null || true
run_sudo iptables -X AIRGAP_HOST 2>/dev/null || true
echo "Air-gap NetworkPolicies and optional host egress firewall were removed."
