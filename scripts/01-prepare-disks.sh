#!/bin/bash
# Home Cloud - preparing the data disks
# WD Red Plus 4 TB -> /mnt/wd (photos, films, backups)
# Barracuda 2 TB   -> /mnt/barracuda (copy of the photos)
set -euo pipefail

SERIE_WD="DISK_SERIAL_WD"
SERIE_BARRA="DISK_SERIAL_BARRACUDA"
SERIE_SYSTEME="DISK_SERIAL_SSD"

trouver() { lsblk -dno NAME,SERIAL | awk -v s="$1" '$2==s{print "/dev/"$1}'; }

WD=$(trouver "$SERIE_WD")
BARRA=$(trouver "$SERIE_BARRA")
SYS=$(trouver "$SERIE_SYSTEME")

echo "=== 1. Identifying the disks by serial number ==="
echo "System (DO NOT TOUCH)    : ${SYS:-not found}"
echo "WD Red Plus 4 TB         : ${WD:-not found}"
echo "Barracuda 2 TB           : ${BARRA:-not found}"
if [ -z "$WD" ] || [ -z "$BARRA" ]; then echo "ERROR: a disk cannot be found, stopping."; exit 1; fi
for D in "$WD" "$BARRA"; do
  if [ "$D" = "$SYS" ]; then echo "ERROR: $D is the system disk, stopping."; exit 1; fi
  if [ -n "$(lsblk -no MOUNTPOINTS "$D" | tr -d '[:space:]')" ]; then echo "ERROR: $D has a mounted partition, stopping."; exit 1; fi
done
echo
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$WD" "$BARRA"
echo
echo "WARNING: everything on $WD (WD) and $BARRA (Barracuda) will be ERASED."
read -r -p "Type YES in capitals to continue: " REP < /dev/tty
if [ "$REP" != "YES" ]; then echo "Cancelled, nothing was changed."; exit 0; fi

echo
echo "=== 2. GPT partitioning and ext4 formatting ==="
command -v parted >/dev/null || apt-get install -y parted
preparer() {
  local D="$1" E="$2" P
  echo "--- $D -> label '$E' ---"
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
echo "=== 3. Automatic mount at boot (/etc/fstab) ==="
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
echo "=== 4. Creating the folders ==="
mkdir -p /mnt/wd/photos /mnt/wd/films /mnt/wd/sauvegardes /mnt/barracuda/copie-photos
ls -la /mnt/wd /mnt/barracuda

echo
echo "=== 5. Backup storage in Proxmox ==="
if pvesm status --storage sauvegardes >/dev/null 2>&1; then
  echo "The 'sauvegardes' storage already exists."
else
  pvesm add dir sauvegardes --path /mnt/wd/sauvegardes --content backup --is_mountpoint /mnt/wd
fi

echo
echo "=== 6. Summary ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$WD" "$BARRA"
echo
df -h /mnt/wd /mnt/barracuda
echo
grep -E "/mnt/(wd|barracuda)" /etc/fstab
echo
pvesm status
echo
echo "DONE."
