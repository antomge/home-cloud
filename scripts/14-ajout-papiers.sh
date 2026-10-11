#!/bin/bash
# Home Cloud - dossier "papiers" (documents personnels) a cote de photos et films
#  - /mnt/wd/papiers, accessible uniquement par anto (ni Jellyfin ni Immich n'y ont acces)
#  - partage SMB [papiers] : chiffrement SMB3 si l'appareil le permet, executables refuses
#  - copie nocturne vers le Barracuda avec corbeille 90 jours, comme les photos
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
if ! mountpoint -q /mnt/wd || ! mountpoint -q /mnt/barracuda; then
  echo "ERREUR : disques non montes."; exit 1
fi
CTID=$(pct list | awk 'NR>1 && $NF=="partage" {print $1}')
if [ -z "$CTID" ]; then echo "ERREUR : conteneur 'partage' introuvable."; exit 1; fi
if pct config "$CTID" | grep -q "mp=/srv/papiers"; then
  echo "Le dossier papiers est deja branche sur le partage, arret."; exit 0
fi

echo "=== 1. Dossier sur le WD (proprietaire : anto du conteneur = 101000) ==="
mkdir -p /mnt/wd/papiers
chown 101000:101000 /mnt/wd/papiers
chmod 700 /mnt/wd/papiers
ls -ldn /mnt/wd/papiers

echo
echo "=== 2. Montage dans le conteneur $CTID (court redemarrage du partage) ==="
MP=""
for i in $(seq 0 9); do
  if ! pct config "$CTID" | grep -q "^mp$i:"; then MP="mp$i"; break; fi
done
pct set "$CTID" -"$MP" /mnt/wd/papiers,mp=/srv/papiers
echo "Montage $MP : /mnt/wd/papiers -> /srv/papiers"
pct reboot "$CTID"
for i in $(seq 1 30); do
  if pct exec "$CTID" -- systemctl is-active --quiet smbd 2>/dev/null; then break; fi
  sleep 2
done
pct exec "$CTID" -- ls -ld /srv/papiers

echo
echo "=== 3. Partage Samba [papiers] ==="
pct exec "$CTID" -- cp -a /etc/samba/smb.conf /etc/samba/smb.conf.avant-papiers
pct exec "$CTID" -- bash -c 'cat >> /etc/samba/smb.conf <<FIN_SMB

[papiers]
   path = /srv/papiers
   valid users = anto
   read only = no
   create mask = 0600
   directory mask = 0700
   server smb encrypt = desired
   veto files = /*.exe/*.bat/*.cmd/*.com/*.scr/*.js/*.vbs/*.ps1/*.msi/
   delete veto files = no
FIN_SMB'
if pct exec "$CTID" -- testparm -s >/dev/null 2>&1; then
  echo "Configuration Samba valide"
else
  pct exec "$CTID" -- cp -a /etc/samba/smb.conf.avant-papiers /etc/samba/smb.conf
  echo "ERREUR dans smb.conf : ancienne configuration remise."; exit 1
fi
pct exec "$CTID" -- systemctl reload smbd
pct exec "$CTID" -- runuser -u anto -- touch /srv/papiers/.test
pct exec "$CTID" -- rm -f /srv/papiers/.test
echo "anto : ECRITURE OK"

echo
echo "=== 4. Copie nocturne : photos ET papiers vers le Barracuda ==="
cp -a /usr/local/sbin/copie-photos.sh /usr/local/sbin/copie-photos.sh.avant-papiers
cat > /usr/local/sbin/copie-photos.sh <<'FIN_COPIE'
#!/bin/bash
# Home Cloud - copie quotidienne vers le Barracuda : photos + papiers
# Les fichiers supprimes ou modifies sur le WD sont gardes 90 jours dans "corbeille".
set -uo pipefail

DOSSIERS="photos papiers"
STATUT=/var/lib/homecloud/copie-photos.statut
JOUR=$(date +%Y-%m-%d_%H%M)
mkdir -p /var/lib/homecloud

echec() { echo "ECHEC $(date '+%Y-%m-%d %H:%M') : $1" | tee "$STATUT"; exit 1; }

mountpoint -q /mnt/wd || echec "le WD n'est pas monte"
mountpoint -q /mnt/barracuda || echec "le Barracuda n'est pas monte"

TOTAL=0
for NOM in $DOSSIERS; do
  SOURCE=/mnt/wd/$NOM/
  DEST=/mnt/barracuda/copie-$NOM/actuel/
  CORBEILLE=/mnt/barracuda/copie-$NOM/corbeille
  [ -d "$SOURCE" ] || echec "dossier source $NOM introuvable"
  mkdir -p "$DEST" "$CORBEILLE"
  chmod 700 "/mnt/barracuda/copie-$NOM"

  NB_SOURCE=$(find "$SOURCE" -type f | wc -l)
  NB_DEST=$(find "$DEST" -type f | wc -l)
  if [ "$NB_SOURCE" -eq 0 ] && [ "$NB_DEST" -gt 0 ]; then
    echec "$NOM : source vide alors que la copie contient $NB_DEST fichiers, copie annulee par securite"
  fi

  nice -n 19 ionice -c3 rsync -a --delete --backup --backup-dir="$CORBEILLE/$JOUR" --stats "$SOURCE" "$DEST"
  CODE=$?
  [ "$CODE" -eq 0 ] || echec "$NOM : rsync a renvoye le code $CODE"

  find "$CORBEILLE" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +
  TOTAL=$((TOTAL + NB_SOURCE))
done

echo "OK $(date '+%Y-%m-%d %H:%M') : $TOTAL fichiers dans la copie (photos + papiers)" | tee "$STATUT"
FIN_COPIE
chmod 755 /usr/local/sbin/copie-photos.sh
systemctl start copie-photos.service
echo -n "Statut : "; cat /var/lib/homecloud/copie-photos.statut
ls -ld /mnt/barracuda/copie-*/actuel

echo
echo "=== 5. Page de liens ==="
LIENS=/opt/supervision/web/liens.html
if [ -f "$LIENS" ] && ! grep -q 'partage-pf\\papiers' "$LIENS"; then
  cp -a "$LIENS" "$LIENS.avant-papiers"
  python3 - "$LIENS" <<'FIN_LIENS'
import sys
p = sys.argv[1]
s = open(p).read()
ancre = '  <button data-copie="\\\\anto-partage-pf\\films">Copier</button></div>\n'
ajout = ('<div class="lien"><div><div class="nom">Papiers</div><div class="det">\\\\anto-partage-pf\\papiers</div></div>\n'
         '  <button data-copie="\\\\anto-partage-pf\\papiers">Copier</button></div>\n')
if s.count(ancre) == 1:
    open(p, "w").write(s.replace(ancre, ancre + ajout))
    print("Lien Papiers ajoute a la page /liens")
else:
    print("Page /liens non modifiee (repere introuvable)")
FIN_LIENS
fi

echo
echo "TERMINE."
echo "PC     : \\\\anto-partage-pf\\papiers   (ou \\\\192.168.1.26\\papiers a la maison)"
echo "iPhone : app Fichiers > serveur anto-partage-pf > papiers"
