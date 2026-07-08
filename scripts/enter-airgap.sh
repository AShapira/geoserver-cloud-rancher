#!/usr/bin/env bash
set -Eeuo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

strict_host_egress=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict-host-egress) strict_host_egress=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config
kube_env
kubectl="$(kubectl_bin)"

policy="$(mktemp)"
cat > "$policy" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: airgap-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
        - ipBlock:
            cidr: 172.16.0.0/12
        - ipBlock:
            cidr: 192.168.0.0/16
EOF

for namespace in $("${kubectl}" get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  "$kubectl" -n "$namespace" apply -f "$policy" >/dev/null
done
rm -f "$policy"

if [[ "$strict_host_egress" -eq 1 ]]; then
  cat > "$STATE_DIR/airgap-host-firewall.sh" <<'EOF'
set -eu
iptables -D OUTPUT -j AIRGAP_HOST 2>/dev/null || true
iptables -F AIRGAP_HOST 2>/dev/null || iptables -N AIRGAP_HOST
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16; do
  iptables -A AIRGAP_HOST -d "$cidr" -j RETURN
done
iptables -A AIRGAP_HOST -j REJECT
iptables -I OUTPUT 1 -j AIRGAP_HOST
EOF
  run_sudo sh "$STATE_DIR/airgap-host-firewall.sh"
fi

canary="$(harbor_runtime_image "$CANARY_IMAGE")"
run_sudo /var/lib/rancher/rke2/bin/crictl rmi "$canary" || true
"$kubectl" -n default delete pod airgap-canary --ignore-not-found >/dev/null
run "$kubectl" -n default run airgap-canary --image="$canary" --restart=Never --command -- sh -c 'sleep 300'
run "$kubectl" -n default wait --for=condition=Ready pod/airgap-canary --timeout=120s
if "$kubectl" -n default exec airgap-canary -- wget -q -T 5 -O /dev/null https://example.com; then
  die "Air-gap validation failed: the canary pod reached example.com."
fi
echo "Air-gap mode is active: registry fallback is disabled and pod egress is blocked."
