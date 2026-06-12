#!/bin/sh
echo "[$(date -Iseconds)] [DNS Fix] Disabled for the internal air-gap network"

if ! ip route | grep -q '^default '; then
  node_ip="$(ip -o -4 addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)"
  gateway="$(echo "$node_ip" | awk -F. '{print $1 "." $2 "." $3 ".1"}')"
  ip route add default via "$gateway" dev eth0
  echo "[$(date -Iseconds)] [Air Gap] Added internal-only default route via $gateway"
fi
