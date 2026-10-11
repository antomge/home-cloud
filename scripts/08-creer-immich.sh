#!/usr/bin/env bash
# =====================================================================
#  creer-immich.sh — Conteneur « immich » (CT 103) du Home Cloud
#  À lancer sur l'hôte Proxmox, en root :   bash /root/creer-immich.sh
#
#  Ce que fait le script :
#   1. vérifie le terrain (WD monté, dossier photos, numéro de CT libre)
#   2. prépare /mnt/wd/immich (miniatures, aperçus vidéo, sauvegardes
#      automatiques de la base) : tout ce qui s'écrit souvent va sur le WD
#   3. crée un conteneur LXC Debian 13 NON privilégié, capable de faire
#      tourner Docker (nesting + keyctl) et Tailscale (/dev/net/tun)
#   4. installe Docker depuis le dépôt officiel
#   5. installe Immich avec les fichiers officiels de la dernière version
#   6. installe Tailscale et rejoint ton réseau sous le nom anto-immich
#
#  Les photos sont montées en LECTURE SEULE : Immich ne peut ni les
#  modifier ni les supprimer (moindre privilège, comme Jellyfin).
# =====================================================================
set -euo pipefail

# ---------- Réglages ----------
CTID=103
NOM_CT="immich"
NOM_TAILSCALE="anto-immich"
STOCKAGE="local-lvm"
DISQUE_GO=24          # système + Docker + modèles d'analyse + base Postgres (SSD)
COEURS=4
MEMOIRE_MO=7168       # PLAFOND (pas une réservation) : le modèle français en a besoin pendant l'analyse
SWAP_MO=1024
PHOTOS_HOTE="/mnt/wd/photos"
DONNEES_HOTE="/mnt/wd/immich"
UID_ROOT_CT=100000    # « root » du conteneur, vu depuis l'hôte (décalage de 100 000)

ok()     { echo -e "\e[32m[OK]\e[0m $*"; }
info()   { echo -e "\e[36m[..]\e[0m $*"; }
alerte() { echo -e "\e[33m[!!]\e[0m $*"; }
stop()   { echo -e "\e[31m[ERREUR]\e[0m $*"; exit 1; }

# ---------- 1. Vérifications ----------
[[ $EUID -eq 0 ]] || stop "À lancer en root sur l'hôte Proxmox."
command -v pct >/dev/null || stop "Commande pct introuvable : es-tu bien sur l'hôte Proxmox ?"
mountpoint -q /mnt/wd || stop "/mnt/wd n'est pas monté."
[[ -d $PHOTOS_HOTE ]] || stop "$PHOTOS_HOTE introuvable."
if pct status "$CTID" &>/dev/null; then
  stop "Le CT $CTID existe déjà. Change CTID en haut du script."
fi
ok "Terrain vérifié"

# ---------- 2. Dossier des données Immich sur le WD ----------
mkdir -p "$DONNEES_HOTE"
chown "$UID_ROOT_CT:$UID_ROOT_CT" "$DONNEES_HOTE"
chmod 750 "$DONNEES_HOTE"
ok "Dossier $DONNEES_HOTE prêt (propriétaire : root du conteneur = $UID_ROOT_CT)"

# ---------- 3. Modèle Debian 13 amd64 ----------
info "Recherche du modèle Debian 13 (amd64)…"
pveam update >/dev/null
MODELE=$(pveam available --section system | awk '{print $2}' \
         | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -n 1 || true)
[[ -n $MODELE ]] || stop "Modèle Debian 13 amd64 introuvable."
if ! pveam list local | grep -F "$MODELE" >/dev/null; then
  info "Téléchargement de $MODELE…"
  pveam download local "$MODELE"
fi
ok "Modèle : $MODELE"

# ---------- 4. Création du conteneur ----------
info "Création du conteneur $CTID ($NOM_CT)…"
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
  --description "Immich : galerie photos + recherche intelligente (modèle multilingue). Créé par creer-immich.sh"

# Accès au périphérique /dev/net/tun pour Tailscale (même méthode que « partage » et « jellyfin »)
cat >> "/etc/pve/lxc/$CTID.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
ok "Conteneur créé"

pct start "$CTID"
info "Attente du réseau dans le conteneur…"
for i in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  [[ $i -eq 30 ]] && stop "Pas de réseau dans le conteneur après 60 s."
  sleep 2
done
ok "Réseau OK"

# ---------- 5. Installation à l'intérieur du conteneur ----------
INTERIEUR=$(mktemp)
cat > "$INTERIEUR" <<'INTERIEUR_FIN'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[..] Mise à jour du système…"
apt-get update -qq
apt-get -y -qq full-upgrade
apt-get -y -qq install ca-certificates curl gnupg

echo "[..] Installation de Docker (dépôt officiel)…"
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

# Journaux Docker : format compact avec rotation (on ménage le SSD)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
systemctl restart docker

if docker run --rm hello-world >/dev/null 2>&1; then
  echo "[OK] Docker fonctionne dans le conteneur LXC"
else
  echo "[ERREUR] Docker n'arrive pas à lancer de conteneur."
  echo "         Envoie-moi le résultat de : pct exec 103 -- docker run --rm hello-world"
  exit 1
fi

echo "[..] Installation d'Immich (fichiers officiels de la dernière version)…"
mkdir -p /opt/immich
cd /opt/immich
curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
curl -fsSL -o .env               https://github.com/immich-app/immich/releases/latest/download/example.env

# Mot de passe Postgres aléatoire (lettres et chiffres uniquement, comme demandé par Immich)
MDP=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
sed -i \
  -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/srv/immich|" \
  -e "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/opt/immich/postgres|" \
  -e "s|^# *TZ=.*|TZ=Europe/Paris|" \
  -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$MDP|" \
  .env
grep -q '^TZ=' .env || echo 'TZ=Europe/Paris' >> .env
chmod 600 .env

# Nos ajouts dans un fichier séparé : le fichier officiel reste intact,
# donc une mise à jour = remplacer docker-compose.yml, sans rien perdre.
cat > docker-compose.override.yml <<'EOF'
services:
  immich-server:
    volumes:
      # Photos rangées par le tri automatique, en LECTURE SEULE
      - /mnt/photos:/mnt/photos:ro
EOF

echo "[..] Téléchargement des images (quelques Go, patience)…"
docker compose pull -q
docker compose up -d

echo "[..] Démarrage d'Immich (1 à 3 minutes)…"
for i in $(seq 1 60); do
  if curl -fs http://127.0.0.1:2283/api/server/ping 2>/dev/null | grep -q pong; then
    echo "[OK] Immich répond sur le port 2283"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[!!] Immich ne répond pas encore. Regarde : cd /opt/immich && docker compose logs --tail 50"
  fi
  sleep 5
done

echo "[..] Installation de Tailscale…"
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
echo "[OK] Installation intérieure terminée"
INTERIEUR_FIN

pct push "$CTID" "$INTERIEUR" /root/installer-immich.sh --perms 700
rm -f "$INTERIEUR"
pct exec "$CTID" -- bash /root/installer-immich.sh

# ---------- 6. Connexion à Tailscale ----------
echo
info "Connexion à Tailscale : ouvre le lien qui va s'afficher et valide avec ton compte."
pct exec "$CTID" -- tailscale up --accept-dns=false --hostname="$NOM_TAILSCALE"
TS_IP=$(pct exec "$CTID" -- tailscale ip -4 2>/dev/null || echo "?")
ok "Tailscale connecté"

# ---------- Récapitulatif ----------
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CTID" | grep -oP 'hwaddr=\K[0-9A-Fa-f:]+' || echo "?")

cat <<EOF

=====================================================================
 Immich est installé dans le CT $CTID
---------------------------------------------------------------------
 IP locale      : $IP   (MAC $MAC → bail statique à faire dans la Livebox)
 IP Tailscale   : $TS_IP  (nom : $NOM_TAILSCALE)
 À la maison    : http://$IP:2283
 Partout        : http://$NOM_TAILSCALE:2283   (PC, appli iPhone)

 Photos         : /mnt/wd/photos → /mnt/photos (LECTURE SEULE)
 Données Immich : /mnt/wd/immich → /srv/immich (miniatures, sauvegardes de la base)
 Base Postgres  : /opt/immich/postgres (SSD, dans le conteneur)
 Mot de passe   : /opt/immich/.env (lisible par root uniquement)

 À faire ensuite :
  1. Console d'administration Tailscale : désactiver l'expiration de clé de $NOM_TAILSCALE
  2. Suivre les étapes de configuration dans l'interface web (voir la conversation)
=====================================================================
EOF
