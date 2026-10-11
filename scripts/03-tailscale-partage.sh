#!/bin/bash
# Home Cloud - Tailscale dans le conteneur "partage" (101)
set -euo pipefail
CTID=101
CONF=/etc/pve/lxc/$CTID.conf

echo "=== 1. Acces du conteneur a la carte reseau virtuelle (/dev/net/tun) ==="
if ! grep -q "c 10:200" "$CONF"; then
  echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
  echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF"
  echo "Lignes ajoutees a $CONF"
else
  echo "Deja present"
fi

echo
echo "=== 2. Redemarrage du conteneur ==="
pct reboot $CTID
for i in $(seq 1 30); do
  if pct exec $CTID -- getent hosts pkgs.tailscale.com >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec $CTID -- ls -l /dev/net/tun

echo
echo "=== 3. Installation de Tailscale (depot officiel) ==="
pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get -y -q install curl ca-certificates && curl -fsSL https://tailscale.com/install.sh | sh"
pct exec $CTID -- systemctl enable --now tailscaled

echo
echo "=== 4. Connexion a ton reseau Tailscale ==="
echo "Scanne le code QR avec ton iPhone (ou ouvre le lien sur ton PC)"
pct exec $CTID -- tailscale up --accept-dns=false --hostname=partage --qr

echo
echo "=== 5. Bilan ==="
pct exec $CTID -- tailscale status
echo
echo -n "Adresse Tailscale du conteneur : "
pct exec $CTID -- tailscale ip -4
