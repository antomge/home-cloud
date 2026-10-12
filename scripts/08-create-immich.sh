#!/usr/bin/env bash
# =====================================================================
#  08-create-immich.sh - "immich" container (CT 103) of the Home Cloud
#  Run on the Proxmox host, as root:   bash /root/08-create-immich.sh
#
#  What the script does:
#   1. checks the ground (WD mounted, photos folder, CT number free)
#   2. prepares /mnt/wd/immich (thumbnails, video previews, automatic
#      database backups): everything that is written often goes on the WD
#   3. creates an UNPRIVILEGED Debian 13 LXC container able to run
#      Docker (nesting + keyctl) and Tailscale (/dev/net/tun)
#   4. installs Docker from the official repository
#   5. installs Immich with the official files of the latest release
#   6. installs Tailscale and joins your network as anto-immich
#
#  The photos are mounted READ-ONLY: Immich can neither modify nor
#  delete them (least privilege, same as Jellyfin).
# =====================================================================
set -euo pipefail

# ---------- Settings ----------
CTID=103
NOM_CT="immich"
NOM_TAILSCALE="anto-immich"
STOCKAGE="local-lvm"
DISQUE_GO=24          # system + Docker + analysis models + Postgres database (SSD)
COEURS=4
MEMOIRE_MO=7168       # CAP (not a reservation): the French model needs it during analysis
SWAP_MO=1024
PHOTOS_HOTE="/mnt/wd/photos"
DONNEES_HOTE="/mnt/wd/immich"
UID_ROOT_CT=100000    # container "root" as seen from the host (offset of 100,000)

ok()     { echo -e "\e[32m[OK]\e[0m $*"; }
info()   { echo -e "\e[36m[..]\e[0m $*"; }
alerte() { echo -e "\e[33m[!!]\e[0m $*"; }
stop()   { echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }

# ---------- 1. Checks ----------
[[ $EUID -eq 0 ]] || stop "Must be run as root on the Proxmox host."
command -v pct >/dev/null || stop "pct command not found: are you really on the Proxmox host?"
mountpoint -q /mnt/wd || stop "/mnt/wd is not mounted."
[[ -d $PHOTOS_HOTE ]] || stop "$PHOTOS_HOTE not found."
if pct status "$CTID" &>/dev/null; then
  stop "CT $CTID already exists. Change CTID at the top of the script."
fi
ok "Ground checked"

# ---------- 2. Immich data folder on the WD ----------
mkdir -p "$DONNEES_HOTE"
chown "$UID_ROOT_CT:$UID_ROOT_CT" "$DONNEES_HOTE"
chmod 750 "$DONNEES_HOTE"
ok "Folder $DONNEES_HOTE ready (owner: container root = $UID_ROOT_CT)"

# ---------- 3. Debian 13 amd64 template ----------
info "Looking for the Debian 13 (amd64) template..."
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '{print $2}' \
         | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -n 1 || true)
[[ -n $MODELE ]] || stop "Debian 13 amd64 template not found."
if ! pveam list local | grep -F "$MODELE" >/dev/null; then
  info "Downloading $MODELE..."
  pveam download local "$MODELE"
fi
ok "Template: $MODELE"

# ---------- 4. Creating the container ----------
info "Creating container $CTID ($NOM_CT)..."
pct create "$CTID" "local:vztmpl/$MODELE" \
  --hostname "$NOM_CT" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores "$COEURS" --memory "$MEMOIRE_MO" --swap "$SWAP_MO" \
  --rootfs "$STOCKAGE:$DISQUE_GO" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --mp0 "$PHOTOS_HOTE,mp=/mnt/photos,ro=1" \
  --mp1 "$DONNEES_HOTE,mp=/srv/immich" \
  --timezone Europe/Paris \
  --onboot 1 --startup order=3 \
  --description "Immich: photo gallery + smart search (multilingual model). Created by 08-create-immich.sh"

# Access to the /dev/net/tun device for Tailscale (same method as "partage" and "jellyfin")
cat >> "/etc/pve/lxc/$CTID.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
ok "Container created"

pct start "$CTID"
info "Waiting for the network inside the container..."
for i in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  [[ $i -eq 30 ]] && stop "No network in the container after 60 s."
  sleep 2
done
ok "Network OK"

# ---------- 5. Installation inside the container ----------
INTERIEUR=$(mktemp)
cat > "$INTERIEUR" <<'INTERIEUR_FIN'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[..] Updating the system..."
apt-get update -qq
apt-get -y -qq full-upgrade
apt-get -y -qq install ca-certificates curl gnupg

echo "[..] Installing Docker (official repository)..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODE
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -qq
apt-get -y -qq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker logs: compact format with rotation (to spare the SSD)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
systemctl restart docker

if docker run --rm hello-world >/dev/null 2>&1; then
  echo "[OK] Docker works inside the LXC container"
else
  echo "[ERROR] Docker cannot start a container."
  echo "        Send me the output of: pct exec 103 -- docker run --rm hello-world"
  exit 1
fi

echo "[..] Installing Immich (official files of the latest release)..."
mkdir -p /opt/immich
cd /opt/immich
curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
curl -fsSL -o .env               https://github.com/immich-app/immich/releases/latest/download/example.env

# Random Postgres password (letters and digits only, as required by Immich)
MDP=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
sed -i \
  -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/srv/immich|" \
  -e "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/opt/immich/postgres|" \
  -e "s|^# *TZ=.*|TZ=Europe/Paris|" \
  -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$MDP|" \
  .env
grep -q '^TZ=' .env || echo 'TZ=Europe/Paris' >> .env
chmod 600 .env

# Our additions go in a separate file: the official file stays untouched,
# so an update = replace docker-compose.yml, without losing anything.
cat > docker-compose.override.yml <<'EOF'
services:
  immich-server:
    volumes:
      # Photos sorted by the automatic sorter, READ-ONLY
      - /mnt/photos:/mnt/photos:ro
EOF

echo "[..] Downloading the images (a few GB, be patient)..."
docker compose pull -q
docker compose up -d

echo "[..] Starting Immich (1 to 3 minutes)..."
for i in $(seq 1 60); do
  if curl -fs http://127.0.0.1:2283/api/server/ping 2>/dev/null | grep -q pong; then
    echo "[OK] Immich is answering on port 2283"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[!!] Immich is not answering yet. Check: cd /opt/immich && docker compose logs --tail 50"
  fi
  sleep 5
done

echo "[..] Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
echo "[OK] Installation inside the container finished"
INTERIEUR_FIN

pct push "$CTID" "$INTERIEUR" /root/installer-immich.sh --perms 700
rm -f "$INTERIEUR"
pct exec "$CTID" -- bash /root/installer-immich.sh

# ---------- 6. Joining Tailscale ----------
echo
info "Joining Tailscale: open the link that will appear and approve it with your account."
pct exec "$CTID" -- tailscale up --accept-dns=false --hostname="$NOM_TAILSCALE"
TS_IP=$(pct exec "$CTID" -- tailscale ip -4 2>/dev/null || echo "?")
ok "Tailscale connected"

# ---------- Summary ----------
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CTID" | grep -oP 'hwaddr=\K[0-9A-Fa-f:]+' || echo "?")

cat <<EOF

=====================================================================
 Immich is installed in CT $CTID
---------------------------------------------------------------------
 Local IP       : $IP   (MAC $MAC -> set a static lease in the Livebox)
 Tailscale IP   : $TS_IP  (name: $NOM_TAILSCALE)
 At home        : http://$IP:2283
 Anywhere       : http://$NOM_TAILSCALE:2283   (PC, iPhone app)

 Photos         : /mnt/wd/photos -> /mnt/photos (READ-ONLY)
 Immich data    : /mnt/wd/immich -> /srv/immich (thumbnails, database backups)
 Postgres DB    : /opt/immich/postgres (SSD, inside the container)
 Password       : /opt/immich/.env (readable by root only)

 Next steps:
  1. Tailscale admin console: disable key expiry for $NOM_TAILSCALE
  2. Follow the setup steps in the web interface (see the docs)
=====================================================================
EOF
