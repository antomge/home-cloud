#!/bin/bash
# Home Cloud - daily copy to the Barracuda: photos + papiers (documents)
# Files deleted or modified on the WD are kept for 90 days in "corbeille" (trash).
set -uo pipefail

DOSSIERS="photos papiers"
STATUT=/var/lib/homecloud/copie-photos.statut
JOUR=$(date +%Y-%m-%d_%H%M)
mkdir -p /var/lib/homecloud

echec() { echo "ECHEC $(date '+%Y-%m-%d %H:%M') : $1" | tee "$STATUT"; exit 1; }

mountpoint -q /mnt/wd || echec "the WD is not mounted"
mountpoint -q /mnt/barracuda || echec "the Barracuda is not mounted"

TOTAL=0
for NOM in $DOSSIERS; do
  SOURCE=/mnt/wd/$NOM/
  DEST=/mnt/barracuda/copie-$NOM/actuel/
  CORBEILLE=/mnt/barracuda/copie-$NOM/corbeille
  [ -d "$SOURCE" ] || echec "source folder $NOM not found"
  mkdir -p "$DEST" "$CORBEILLE"
  chmod 700 "/mnt/barracuda/copie-$NOM"

  NB_SOURCE=$(find "$SOURCE" -type f | wc -l)
  NB_DEST=$(find "$DEST" -type f | wc -l)
  if [ "$NB_SOURCE" -eq 0 ] && [ "$NB_DEST" -gt 0 ]; then
    echec "$NOM: source is empty while the copy holds $NB_DEST files, copy cancelled as a safety measure"
  fi

  nice -n 19 ionice -c3 rsync -a --delete --backup --backup-dir="$CORBEILLE/$JOUR" --stats "$SOURCE" "$DEST"
  CODE=$?
  [ "$CODE" -eq 0 ] || echec "$NOM: rsync returned code $CODE"

  find "$CORBEILLE" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +
  TOTAL=$((TOTAL + NB_SOURCE))
done

echo "OK $(date '+%Y-%m-%d %H:%M') : $TOTAL files in the copy (photos + papiers)" | tee "$STATUT"
