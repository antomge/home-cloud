#!/bin/bash
# Home Cloud - preparation des disques de donnees
# WD Red Plus 4 To -> /mnt/wd (photos, films, sauvegardes)
# Barracuda 2 To   -> /mnt/barracuda (copie des photos)
set -euo pipefail

SERIE_WD="NUMERO_SERIE_WD"
SERIE_BARRA="NUMERO_SERIE_BARRACUDA"
SERIE_SYSTEME="NUMERO_SERIE_SSD"

trouver() { lsblk -dno NAME,SERIAL | awk -v s="$1" '$2==s{print "/dev/"$1}'; }

WD=$(trouver "$SERIE_WD")
BARRA=$(trouver "$SERIE_BARRA")
SYS=$(trouver "$SERIE_SYSTEME")

echo "=== 1. Identification des disques par numero de serie ==="
echo "Systeme (NE PAS TOUCHER) : ${SYS:-introuvable}"
echo "WD Red Plus 4 To         : ${WD:-introuvable}"
echo "Barracuda 2 To           : ${BARRA:-introuvable}"
if [ -z "$WD" ] || [ -z "$BARRA" ]; then echo "ERREUR : un disque est introuvable, arret."; exit 1; fi
for D in "$WD" "$BARRA"; do
  if [ "$D" = "$SYS" ]; then echo "ERREUR : $D est le disque systeme, arret."; exit 1; fi
  if [ -n "$(lsblk -no MOUNTPOINTS "$D" | tr -d '[:space:]')" ]; then echo "ERREUR : $D a une partition montee, arret."; exit 1; fi
done
echo
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$WD" "$BARRA"
echo
echo "ATTENTION : tout le contenu de $WD (WD) et de $BARRA (Barracuda) va etre EFFACE."
read -r -p "Tape OUI en majuscules pour continuer : " REP < /dev/tty
if [ "$REP" != "OUI" ]; then echo "Annule, rien n'a ete modifie."; exit 0; fi

echo
echo "=== 2. Partitionnement GPT et formatage ext4 ==="
command -v parted >/dev/null || apt-get install -y parted
preparer() {
  local D="$1" E="$2" P
  echo "--- $D -> etiquette '$E' ---"
  for P in $(lsblk -lnpo NAME,TYPE "$D" | awk '$2=="part"{print $1}'); do wipefs -a "$P"; done
  wipefs -a "$D"
  parted -s "$D" mklabel gpt mkpart "$E" ext4 0% 100%
  partprobe "$D"; udevadm settle; sleep 2
  P=$(lsblk -lnpo NAME,TYPE "$D" | awk '$2=="part"{print $1}')
  mkfs.ext4 -F -m 0 -L "$E" "$P"
}
preparer "$WD" donnees
preparer "$BARRA" copie
udevadm settle; sleep 2

echo
echo "=== 3. Montage automatique au demarrage (/etc/fstab) ==="
UUID_WD=$(blkid -s UUID -o value "$(blkid -L donnees)")
UUID_BARRA=$(blkid -s UUID -o value "$(blkid -L copie)")
mkdir -p /mnt/wd /mnt/barracuda
cp /etc/fstab "/etc/fstab.sauvegarde-$(date +%Y%m%d-%H%M%S)"
sed -i '\#[[:space:]]/mnt/wd[[:space:]]#d; \#[[:space:]]/mnt/barracuda[[:space:]]#d' /etc/fstab
echo "UUID=$UUID_WD /mnt/wd ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
echo "UUID=$UUID_BARRA /mnt/barracuda ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount /mnt/wd
mount /mnt/barracuda

echo
echo "=== 4. Creation des dossiers ==="
mkdir -p /mnt/wd/photos /mnt/wd/films /mnt/wd/sauvegardes /mnt/barracuda/copie-photos
ls -la /mnt/wd /mnt/barracuda

echo
echo "=== 5. Stockage de sauvegarde dans Proxmox ==="
if pvesm status --storage sauvegardes >/dev/null 2>&1; then
  echo "Le stockage 'sauvegardes' existe deja."
else
  pvesm add dir sauvegardes --path /mnt/wd/sauvegardes --content backup --is_mountpoint /mnt/wd
fi

echo
echo "=== 6. Bilan ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$WD" "$BARRA"
echo
df -h /mnt/wd /mnt/barracuda
echo
grep -E "/mnt/(wd|barracuda)" /etc/fstab
echo
pvesm status
echo
echo "TERMINE."
