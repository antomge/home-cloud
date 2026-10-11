#!/bin/bash
# Home Cloud - conteneur "jellyfin" (102) avec Quick Sync et Tailscale
set -euo pipefail
CTID=102
NOM=jellyfin
CONF=/etc/pve/lxc/$CTID.conf
TRANSCODAGE=/mnt/wd/transcodage-jellyfin

echo "=== 0. Verifications ==="
if pct status $CTID >/dev/null 2>&1; then echo "ERREUR : le conteneur $CTID existe deja, arret."; exit 1; fi
if ! mountpoint -q /mnt/wd; then echo "ERREUR : /mnt/wd n'est pas monte, arret."; exit 1; fi
if [ ! -e /dev/dri/renderD128 ]; then echo "ERREUR : puce graphique Intel introuvable, arret."; exit 1; fi
ls -l /dev/dri
echo "OK"

echo
echo "=== 1. Modele Debian 13 (amd64) ==="
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64/ {print $2}' | sort -V | tail -n 1)
if [ -z "$MODELE" ]; then echo "ERREUR : modele introuvable."; exit 1; fi
if [ ! -f "/var/lib/vz/template/cache/$MODELE" ]; then pveam download local "$MODELE"; fi
echo "Modele : $MODELE"

echo
echo "=== 2. Creation du conteneur $CTID ($NOM) ==="
mkdir -p "$TRANSCODAGE"
pct create $CTID "local:vztmpl/$MODELE" \
  --hostname $NOM --ostype debian --unprivileged 1 --features nesting=1 \
  --cores 4 --memory 3072 --swap 512 --rootfs local-lvm:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0 \
  --onboot 1 --startup order=2 --timezone host
pct set $CTID --mp0 /mnt/wd/films,mp=/media/films,ro=1 --mp1 "$TRANSCODAGE",mp=/transcodage
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF"
echo "Films en lecture seule, transcodage sur le WD, acces Tailscale prepare"

echo
echo "=== 3. Demarrage et acces a la puce graphique (Quick Sync) ==="
attendre_reseau() {
  for i in $(seq 1 30); do
    if pct exec $CTID -- getent hosts deb.debian.org >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "ERREUR : pas d'acces internet dans le conteneur."; exit 1
}
pct start $CTID
attendre_reseau
pct exec $CTID -- bash -c 'getent group render >/dev/null || groupadd -r render'
GID_RENDER=$(pct exec $CTID -- getent group render | cut -d: -f3)
echo "Groupe 'render' du conteneur : GID $GID_RENDER"
pct stop $CTID
pct set $CTID --dev0 /dev/dri/renderD128,gid=$GID_RENDER
pct start $CTID
attendre_reseau
pct exec $CTID -- ls -l /dev/dri/renderD128

echo
echo "=== 4. Mises a jour et installation de Jellyfin (depot officiel) ==="
pct exec $CTID -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get -y -q full-upgrade
apt-get -y -q install curl gnupg ca-certificates
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/jellyfin.gpg
ecrire_depot() {
cat > /etc/apt/sources.list.d/jellyfin.sources <<DEPOT
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: $1
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/jellyfin.gpg
DEPOT
}
ecrire_depot trixie
if ! apt-get update -q; then
  echo "Depot trixie indisponible, utilisation de bookworm"
  ecrire_depot bookworm
  apt-get update -q
fi
apt-get -y -q install jellyfin
'

echo
echo "=== 5. Droits : puce graphique et dossier de transcodage ==="
pct exec $CTID -- usermod -aG render,video jellyfin
UID_JF=$(pct exec $CTID -- id -u jellyfin)
GID_JF=$(pct exec $CTID -- id -g jellyfin)
chown $((100000 + UID_JF)):$((100000 + GID_JF)) "$TRANSCODAGE"
pct exec $CTID -- systemctl restart jellyfin
sleep 5
echo -n "Jellyfin : "; pct exec $CTID -- systemctl is-active jellyfin

echo
echo "=== 6. Test de Quick Sync ==="
pct exec $CTID -- runuser -u jellyfin -- /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -E "Driver version|VAProfileH264Main|VAProfileHEVCMain " || echo "ATTENTION : test Quick Sync non concluant, on regardera ensemble"

echo
echo "=== 7. Tailscale ==="
pct exec $CTID -- bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
pct exec $CTID -- systemctl enable --now tailscaled
echo "Scanne le code QR avec ton iPhone (ou ouvre le lien sur ton PC)"
pct exec $CTID -- tailscale up --accept-dns=false --hostname=jellyfin --qr

echo
echo "=== 8. Bilan ==="
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
MAC=$(pct config $CTID | sed -n 's/^net0:.*hwaddr=\([0-9A-Fa-f:]*\).*/\1/p')
TS=$(pct exec $CTID -- tailscale ip -4)
echo "Conteneur $CTID ($NOM)  |  IP : $IP  |  MAC : $MAC  |  Tailscale : $TS"
echo "Configuration initiale (depuis ton PC) : http://$IP:8096"
echo "Depuis Streamyfin (partout)            : http://jellyfin:8096  ou  http://$TS:8096"
echo "TERMINE."
