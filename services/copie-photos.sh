#!/bin/bash
# Home Cloud - copie quotidienne des photos : WD -> Barracuda
# Les fichiers supprimes ou modifies sur le WD sont gardes 90 jours dans "corbeille".
set -uo pipefail

SOURCE=/mnt/wd/photos/
DEST=/mnt/barracuda/copie-photos/actuel/
CORBEILLE=/mnt/barracuda/copie-photos/corbeille
STATUT=/var/lib/homecloud/copie-photos.statut
JOUR=$(date +%Y-%m-%d_%H%M)
mkdir -p /var/lib/homecloud

echec() { echo "ECHEC $(date '+%Y-%m-%d %H:%M') : $1" | tee "$STATUT"; exit 1; }

mountpoint -q /mnt/wd || echec "le WD n'est pas monte"
mountpoint -q /mnt/barracuda || echec "le Barracuda n'est pas monte"
[ -d "$SOURCE" ] || echec "dossier source introuvable"
mkdir -p "$DEST" "$CORBEILLE"

NB_SOURCE=$(find "$SOURCE" -type f | wc -l)
NB_DEST=$(find "$DEST" -type f | wc -l)
if [ "$NB_SOURCE" -eq 0 ] && [ "$NB_DEST" -gt 0 ]; then
  echec "source vide alors que la copie contient $NB_DEST fichiers : copie annulee par securite"
fi

nice -n 19 ionice -c3 rsync -a --delete --backup --backup-dir="$CORBEILLE/$JOUR" --stats "$SOURCE" "$DEST"
CODE=$?
[ "$CODE" -eq 0 ] || echec "rsync a renvoye le code $CODE"

find "$CORBEILLE" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +

echo "OK $(date '+%Y-%m-%d %H:%M') : $NB_SOURCE fichiers dans la copie" | tee "$STATUT"
