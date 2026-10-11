#!/bin/bash
# Home Cloud - conteneur "adguard" : bloqueur de publicites (serveur DNS)
# pour tous les appareils connectes a Tailscale, a la maison comme en 5G.
set -euo pipefail
NOM=adguard
STOCKAGE=local-lvm

if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
if pct list | awk 'NR>1 {print $NF}' | grep -qx "$NOM"; then
  echo "Un conteneur nomme $NOM existe deja, arret."; exit 1
fi
CTID=$(pvesh get /cluster/nextid)

echo "=== 1. Modele Debian 13 (amd64) ==="
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '{print $2}' \
  | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -n1)
if [ -z "$MODELE" ]; then echo "ERREUR : modele Debian 13 introuvable"; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
echo "Modele : $MODELE"

echo
echo "=== 2. Creation du conteneur $CTID ($NOM) ==="
pct create "$CTID" "local:vztmpl/$MODELE" \
  --hostname "$NOM" --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs "$STOCKAGE:4" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 1 --startup order=1 \
  --description "Bloqueur de publicites (AdGuard Home) pour les appareils Tailscale"

# Autoriser le peripherique /dev/net/tun (indispensable a Tailscale dans un conteneur)
cat >> "/etc/pve/lxc/$CTID.conf" <<'FIN_TUN'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
FIN_TUN

pct start "$CTID"
echo -n "Attente du reseau"
for i in $(seq 1 40); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 2
done
echo

echo
echo "=== 3. Mises a jour du conteneur ==="
pct exec "$CTID" -- bash -c 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade'
pct exec "$CTID" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates'

echo
echo "=== 4. Installation d'AdGuard Home (script officiel) ==="
pct exec "$CTID" -- bash -c \
  'curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v'
pct exec "$CTID" -- systemctl is-active AdGuardHome

echo
echo "=== 5. Installation de Tailscale ==="
pct exec "$CTID" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
echo
echo ">>> Un lien va s'afficher : ouvre-le et valide l'ajout de la machine a ton compte Tailscale."
pct exec "$CTID" -- tailscale up --accept-dns=false --hostname=anto-adguard

TSIP=$(pct exec "$CTID" -- tailscale ip -4 | head -n1)
LANIP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CTID" | grep -o 'hwaddr=[^,]*' | cut -d= -f2)

echo
echo "=================== BILAN ==================="
echo "Conteneur        : $CTID ($NOM), demarrage automatique en premier"
echo "IP maison        : $LANIP   (MAC $MAC)"
echo "IP Tailscale     : $TSIP   (nom anto-adguard)"
echo "Assistant AdGuard: http://$TSIP:3000   (ou http://$LANIP:3000 a la maison)"
echo "Etape suivante   : console Tailscale > DNS > serveur de noms personnalise = $TSIP"
echo "============================================="
