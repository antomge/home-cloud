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
