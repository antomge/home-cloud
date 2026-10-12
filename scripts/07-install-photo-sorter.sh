#!/bin/bash
# Home Cloud - automatic photo sorting (year / month) every 5 minutes
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
if ! mountpoint -q /mnt/wd; then echo "ERROR: the WD disk is not mounted."; exit 1; fi

echo "=== 1. Installing exiftool (reads photo metadata) ==="
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q libimage-exiftool-perl
exiftool -ver

echo
echo "=== 2. Sorting script ==="
cat > /usr/local/sbin/tri-photos.py <<'FIN_TRI'
#!/usr/bin/env python3
"""Home Cloud - automatic photo sorting by year, then by month.

Photos and videos dropped AT THE ROOT of the photos folder are moved into
  photos/YYYY/MM - Month/
based on their capture date (EXIF metadata), otherwise on their file name,
otherwise on their modification date. Existing subfolders are never
touched. Nothing is ever deleted: an exact duplicate goes to
photos/_doublons/, a different file with the same name gets a " (1)" suffix.
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
PROPRIETAIRE = (101000, 101000)   # anto inside the "partage" container
DELAI_STABLE = 120                # seconds without modification before sorting (upload finished)
EXTENSIONS = {".jpg", ".jpeg", ".heic", ".heif", ".png", ".gif", ".webp", ".tif", ".tiff",
              ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2",
              ".mov", ".mp4", ".m4v", ".avi", ".3gp", ".mts"}
MOIS = ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Août",
        "Septembre", "Octobre", "Novembre", "Décembre"]
# Date tags, from most to least reliable
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
    """Queries exiftool only once for all files (much faster)."""
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
        return int(m.group(1)), int(m.group(2)), "file name"
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
        # every level created must belong to anto so he can write to it from the share
        partie = chemin
        while partie != RACINE and partie.startswith(RACINE):
            os.chown(partie, *PROPRIETAIRE)
            os.chmod(partie, 0o755)
            partie = os.path.dirname(partie)


def destination_libre(dossier, nom, source):
    """Returns (destination_path, is_a_duplicate)."""
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
        journal(f"ERROR: folder {RACINE} not found")
        return 1
    verrou = open("/tmp/tri-photos.lock", "w")
    try:
        fcntl.flock(verrou, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # a sort is already running

    maintenant = time.time()
    candidats = []
    for nom in sorted(os.listdir(RACINE)):
        chemin = os.path.join(RACINE, nom)
        if not os.path.isfile(chemin) or nom.startswith("."):
            continue
        if os.path.splitext(nom)[1].lower() not in EXTENSIONS:
            continue
        if maintenant - os.path.getmtime(chemin) < DELAI_STABLE:
            continue  # still uploading, wait for the next run
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
            info = (mt.year, mt.month, "modification date")
        annee, mois, origine = info
        dossier = os.path.join(RACINE, f"{annee:04d}", f"{mois:02d} - {MOIS[mois - 1]}")
        creer_dossier(dossier)
        cible, est_doublon = destination_libre(dossier, nom, chemin)
        if est_doublon:
            dossier_doublons = os.path.join(RACINE, "_doublons")
            creer_dossier(dossier_doublons)
            cible, _ = destination_libre(dossier_doublons, nom, chemin)
            if cible is None:  # already present in _doublons too
                cible = os.path.join(dossier_doublons, f"{time.time_ns()}_{nom}")
            shutil.move(chemin, cible)
            doublons += 1
            journal(f"DUPLICATE {nom} -> _doublons/")
            continue
        shutil.move(chemin, cible)
        ranges += 1
        journal(f"SORTED    {nom} -> {os.path.relpath(cible, RACINE)}  ({origine})")

    resume = f"OK {datetime.datetime.now():%Y-%m-%d %H:%M} : {ranges} sorted, {doublons} duplicate(s)"
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
echo "=== 3. Service and timer (every 5 minutes) ==="
cat > /etc/systemd/system/tri-photos.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - sort photos by year and month
RequiresMountsFor=/mnt/wd

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/tri-photos.py
Nice=19
IOSchedulingClass=idle
FIN_UNITE

cat > /etc/systemd/system/tri-photos.timer <<'FIN_UNITE'
[Unit]
Description=Photo sorting every 5 minutes

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
echo "=== 4. First sort, right now ==="
systemctl start tri-photos.service
echo
tail -n 20 /var/log/tri-photos.log 2>/dev/null || echo "Nothing to sort yet"
echo
echo "=== 5. New layout of the photos folder ==="
find /mnt/wd/photos -maxdepth 2 -type d | sort
echo
systemctl list-timers tri-photos.timer --no-pager
