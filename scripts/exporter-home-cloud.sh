#!/bin/bash
# Home Cloud - rassemble scripts et configurations (SANS SECRETS) pour le depot GitHub
set -uo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
D=$(mktemp -d)/home-cloud-export
mkdir -p "$D"/{scripts,sbin,supervision,systemd,configs/lxc,configs/conteneurs}

echo "=== 1. Scripts d'installation (/root) ==="
cp -v /root/*.sh "$D/scripts/" 2>/dev/null
rm -f "$D/scripts/exporter-home-cloud.sh"

echo
echo "=== 2. Scripts de service et supervision ==="
for f in copie-photos.sh releve-smart.py tri-photos.py finops-releve.py finops-azure.py; do
  [ -f "/usr/local/sbin/$f" ] && cp -v "/usr/local/sbin/$f" "$D/sbin/"
done
cp -v /opt/supervision/collecteur.py "$D/supervision/" 2>/dev/null
cp -v /opt/supervision/web/*.html "$D/supervision/" 2>/dev/null
for u in supervision ecran-supervision releve-smart copie-photos tri-photos finops-releve finops-azure; do
  for t in service timer; do
    [ -f "/etc/systemd/system/$u.$t" ] && cp "/etc/systemd/system/$u.$t" "$D/systemd/"
  done
done
ls "$D/systemd"

echo
echo "=== 3. Configurations (sans secrets) ==="
cp /etc/fstab "$D/configs/fstab"
cp /etc/pve/jobs.cfg "$D/configs/jobs.cfg" 2>/dev/null
cp /etc/homecloud/finops.json "$D/configs/finops.json" 2>/dev/null
for id in $(pct list | awk 'NR>1 {print $1}'); do
  nom=$(pct config "$id" | awk '/^hostname:/ {print $2}')
  pct config "$id" > "$D/configs/lxc/$id-$nom.conf"
done
CT_PARTAGE=$(pct list | awk 'NR>1 && $NF=="partage" {print $1}')
CT_PROXY=$(pct list | awk 'NR>1 && $NF=="proxy" {print $1}')
[ -n "$CT_PARTAGE" ] && pct exec "$CT_PARTAGE" -- cat /etc/samba/smb.conf > "$D/configs/conteneurs/smb.conf"
[ -n "$CT_PROXY" ] && pct exec "$CT_PROXY" -- cat /etc/caddy/Caddyfile > "$D/configs/conteneurs/Caddyfile"
ls -R "$D/configs"

echo
echo "=== 4. Controle anti-secrets ==="
ALERTE=$(grep -rnEi '(PVEAPIToken=[^ "$]+=[0-9a-f-]{8,}|CF_API_TOKEN=[A-Za-z0-9_-]{20,}|MediaBrowser Token="[0-9a-f]{32}"|password *[:=] *[^ ]{6,}|\b[0-9a-f]{32}\b)' "$D" \
  | grep -v 'smb.conf.*passdb' || true)
if [ -n "$ALERTE" ]; then
  echo "ATTENTION, elements a verifier :"; echo "$ALERTE" | cut -c1-160
else
  echo "Aucun secret detecte."
fi

tar -czf /root/home-cloud-export.tar.gz -C "$(dirname "$D")" home-cloud-export
rm -rf "$(dirname "$D")"
echo
echo "TERMINE : /root/home-cloud-export.tar.gz ($(du -h /root/home-cloud-export.tar.gz | cut -f1))"
