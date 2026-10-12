#!/bin/bash
# Home Cloud - "adguard" container: ad blocker (DNS server)
# for every device connected to Tailscale, at home as well as on 5G.
set -euo pipefail
NOM=adguard
STOCKAGE=local-lvm

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
if pct list | awk 'NR>1 {print $NF}' | grep -qx "$NOM"; then
  echo "A container named $NOM already exists, stopping."; exit 1
fi
CTID=$(pvesh get /cluster/nextid)

echo "=== 1. Debian 13 template (amd64) ==="
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '{print $2}' \
  | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -n1)
if [ -z "$MODELE" ]; then echo "ERROR: Debian 13 template not found"; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
echo "Template: $MODELE"

echo
echo "=== 2. Creating container $CTID ($NOM) ==="
pct create "$CTID" "local:vztmpl/$MODELE" \
  --hostname "$NOM" --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs "$STOCKAGE:4" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 1 --startup order=1 \
  --description "Ad blocker (AdGuard Home) for Tailscale devices"

# Allow the /dev/net/tun device (required for Tailscale inside a container)
cat >> "/etc/pve/lxc/$CTID.conf" <<'FIN_TUN'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
FIN_TUN

pct start "$CTID"
echo -n "Waiting for the network"
for i in $(seq 1 40); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 2
done
echo

echo
echo "=== 3. Container updates ==="
pct exec "$CTID" -- bash -c 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade'
pct exec "$CTID" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates'

echo
echo "=== 4. Installing AdGuard Home (official script) ==="
pct exec "$CTID" -- bash -c \
  'curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v'
pct exec "$CTID" -- systemctl is-active AdGuardHome

echo
echo "=== 5. Installing Tailscale ==="
pct exec "$CTID" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
echo
echo ">>> A link will appear: open it and approve adding the machine to your Tailscale account."
pct exec "$CTID" -- tailscale up --accept-dns=false --hostname=anto-adguard

TSIP=$(pct exec "$CTID" -- tailscale ip -4 | head -n1)
LANIP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CTID" | grep -o 'hwaddr=[^,]*' | cut -d= -f2)

echo
echo "=================== SUMMARY ================="
echo "Container        : $CTID ($NOM), starts automatically first"
echo "Home IP          : $LANIP   (MAC $MAC)"
echo "Tailscale IP     : $TSIP   (name anto-adguard)"
echo "AdGuard wizard   : http://$TSIP:3000   (or http://$LANIP:3000 at home)"
echo "Next step        : Tailscale console > DNS > custom nameserver = $TSIP"
echo "============================================="
