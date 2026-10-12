#!/bin/bash
# Home Cloud - Tailscale in the "partage" container (101)
set -euo pipefail
CTID=101
CONF=/etc/pve/lxc/$CTID.conf

echo "=== 1. Container access to the virtual network device (/dev/net/tun) ==="
if ! grep -q "c 10:200" "$CONF"; then
  echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
  echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF"
  echo "Lines added to $CONF"
else
  echo "Already present"
fi

echo
echo "=== 2. Restarting the container ==="
pct reboot $CTID
for i in $(seq 1 30); do
  if pct exec $CTID -- getent hosts pkgs.tailscale.com >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec $CTID -- ls -l /dev/net/tun

echo
echo "=== 3. Installing Tailscale (official repository) ==="
pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get -y -q install curl ca-certificates && curl -fsSL https://tailscale.com/install.sh | sh"
pct exec $CTID -- systemctl enable --now tailscaled

echo
echo "=== 4. Joining your Tailscale network ==="
echo "Scan the QR code with your iPhone (or open the link on your PC)"
pct exec $CTID -- tailscale up --accept-dns=false --hostname=partage --qr

echo
echo "=== 5. Summary ==="
pct exec $CTID -- tailscale status
echo
echo -n "Container Tailscale address: "
pct exec $CTID -- tailscale ip -4
