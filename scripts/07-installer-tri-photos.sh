#!/bin/bash
# Home Cloud - tri automatique des photos (annee / mois) toutes les 5 minutes
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
if ! mountpoint -q /mnt/wd; then echo "ERREUR : le WD n'est pas monte."; exit 1; fi

echo "=== 1. Installation d'exiftool (lecture des metadonnees des photos) ==="
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q libimage-exiftool-perl
exiftool -ver

echo
echo "=== 2. Script de tri ==="
cat > /usr/local/sbin/tri-photos.py <<'FIN_TRI'
#!/usr/bin/env python3
"""Home Cloud - tri automatique des photos par annee puis par mois.

Les photos et videos deposees A LA RACINE du dossier photos sont rangees dans
  photos/AAAA/MM - Mois/
d'apres leur date de prise de vue (metadonnees EXIF), sinon d'apres leur nom,
sinon d'apres leur date de modification. Les sous-dossiers existants ne sont
jamais touches. Rien n'est jamais supprime : un doublon exact part dans
photos/_doublons/, un homonyme different recoit un suffixe " (1)".
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

RACINE = os.environ.get("RACINE_PHOTOS", "/mnt/wd/photos")
EXIFTOOL = os.environ.get("EXIFTOOL", "exiftool")
JOURNAL = os.environ.get("JOURNAL_TRI", "/var/log/tri-photos.log")
STATUT = os.environ.get("STATUT_TRI", "/var/lib/homecloud/tri-photos.statut")
PROPRIETAIRE = (101000, 101000)   # anto dans le conteneur "partage"
DELAI_STABLE = 120                # secondes sans modification avant de trier (envoi termine)
EXTENSIONS = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".gif", ".webp", ".tif", ".tiff",
              ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2",
              ".mov", ".mp4", ".m4v", ".avi", ".3gp", ".mts"}
MOIS = ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Août",
        "Septembre", "Octobre", "Novembre", "Décembre"]
# Balises de date, de la plus fiable a la moins fiable
BALISES = ["DateTimeOriginal", "CreationDate", "SubSecDateTimeOriginal", "CreateDate",
           "MediaCreateDate", "DateCreated"]
MOTIF_NOM = re.compile(r"(?<!\d)(20\d{2}|19\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)")


def journal(message):
    ligne = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
    print(ligne)
    try:
        with open(JOURNAL, "a") as f:
            f.write(ligne + "\n")
    except OSError:
        pass


def lire_dates_exif(fichiers):
    """Interroge exiftool une seule fois pour tous les fichiers (bien plus rapide)."""
    if not fichiers:
        return {}
    cmd = [EXIFTOOL, "-json", "-api", "QuickTimeUTC", "-d", "%Y-%m-%d %H:%M:%S"]
    cmd += ["-" + b for b in BALISES] + fichiers
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        donnees = json.loads(r.stdout or "[]")
    except ValueError:
        return {}
    resultat = {}
    for d in donnees:
        for b in BALISES:
            v = str(d.get(b, ""))
            m = re.match(r"(\d{4})-(\d{2})-(\d{2})", v)
            if m and m.group(1) not in ("0000", "1970"):
                resultat[d.get("SourceFile")] = (int(m.group(1)), int(m.group(2)), b)
                break
    return resultat


def date_depuis_nom(nom):
    m = MOTIF_NOM.search(nom)
    if m:
        return int(m.group(1)), int(m.group(2)), "nom du fichier"
    return None


def empreinte(chemin):
    h = hashlib.sha256()
    with open(chemin, "rb") as f:
        for bloc in iter(lambda: f.read(1 << 20), b""):
            h.update(bloc)
    return h.hexdigest()


def creer_dossier(chemin):
    if not os.path.isdir(chemin):
        os.makedirs(chemin, exist_ok=True)
        # chaque niveau cree doit appartenir a anto pour qu'il puisse y ecrire depuis le partage
        partie = chemin
        while partie != RACINE and partie.startswith(RACINE):
            os.chown(partie, *PROPRIETAIRE)
            os.chmod(partie, 0o755)
            partie = os.path.dirname(partie)


def destination_libre(dossier, nom, source):
    """Renvoie (chemin_destination, est_un_doublon)."""
    cible = os.path.join(dossier, nom)
    if not os.path.exists(cible):
        return cible, False
    if os.path.getsize(cible) == os.path.getsize(source) and empreinte(cible) == empreinte(source):
        return None, True
    base, ext = os.path.splitext(nom)
    n = 1
    while os.path.exists(os.path.join(dossier, f"{base} ({n}){ext}")):
        n += 1
    return os.path.join(dossier, f"{base} ({n}){ext}"), False


def main():
    if not os.path.isdir(RACINE):
        journal(f"ERREUR : dossier {RACINE} introuvable")
        return 1
    verrou = open("/tmp/tri-photos.lock", "w")
    try:
        fcntl.flock(verrou, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # un tri est deja en cours

    maintenant = time.time()
    candidats = []
    for nom in sorted(os.listdir(RACINE)):
        chemin = os.path.join(RACINE, nom)
        if not os.path.isfile(chemin) or nom.startswith("."):
            continue
        if os.path.splitext(nom)[1].lower() not in EXTENSIONS:
            continue
        if maintenant - os.path.getmtime(chemin) < DELAI_STABLE:
            continue  # encore en cours d'envoi, on attend le prochain passage
        candidats.append(chemin)

    if not candidats:
        return 0

    dates = lire_dates_exif(candidats)
    ranges, doublons = 0, 0
    for chemin in candidats:
        nom = os.path.basename(chemin)
        info = dates.get(chemin) or date_depuis_nom(nom)
        if not info:
            mt = datetime.datetime.fromtimestamp(os.path.getmtime(chemin))
            info = (mt.year, mt.month, "date de modification")
        annee, mois, origine = info
        dossier = os.path.join(RACINE, f"{annee:04d}", f"{mois:02d} - {MOIS[mois - 1]}")
        creer_dossier(dossier)
        cible, est_doublon = destination_libre(dossier, nom, chemin)
        if est_doublon:
            dossier_doublons = os.path.join(RACINE, "_doublons")
            creer_dossier(dossier_doublons)
            cible, _ = destination_libre(dossier_doublons, nom, chemin)
            if cible is None:  # deja present aussi dans _doublons
                cible = os.path.join(dossier_doublons, f"{time.time_ns()}_{nom}")
            shutil.move(chemin, cible)
            doublons += 1
            journal(f"DOUBLON  {nom} -> _doublons/")
            continue
        shutil.move(chemin, cible)
        ranges += 1
        journal(f"RANGE    {nom} -> {os.path.relpath(cible, RACINE)}  ({origine})")

    resume = f"OK {datetime.datetime.now():%Y-%m-%d %H:%M} : {ranges} rangee(s), {doublons} doublon(s)"
    journal(resume)
    try:
        os.makedirs(os.path.dirname(STATUT), exist_ok=True)
        with open(STATUT, "w") as f:
            f.write(resume + "\n")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
FIN_TRI
chmod 755 /usr/local/sbin/tri-photos.py

echo
echo "=== 3. Service et minuteur (toutes les 5 minutes) ==="
cat > /etc/systemd/system/tri-photos.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - tri des photos par annee et par mois
RequiresMountsFor=/mnt/wd

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/tri-photos.py
Nice=19
IOSchedulingClass=idle
FIN_UNITE

cat > /etc/systemd/system/tri-photos.timer <<'FIN_UNITE'
[Unit]
Description=Tri des photos toutes les 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
FIN_UNITE

cat > /etc/logrotate.d/tri-photos <<'FIN_ROT'
/var/log/tri-photos.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
FIN_ROT

systemctl daemon-reload
systemctl enable --now tri-photos.timer

echo
echo "=== 4. Premier tri, tout de suite ==="
systemctl start tri-photos.service
echo
tail -n 20 /var/log/tri-photos.log 2>/dev/null || echo "Rien a trier pour l'instant"
echo
echo "=== 5. Nouvelle organisation du dossier photos ==="
find /mnt/wd/photos -maxdepth 2 -type d | sort
echo
systemctl list-timers tri-photos.timer --no-pager
