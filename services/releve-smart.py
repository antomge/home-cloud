#!/usr/bin/env python3
"""Home Cloud - releve SMART des disques (lance par root toutes les 10 min).
Ecrit /var/lib/homecloud/smart.json, lu par le collecteur de l'ecran."""
import json
import os
import subprocess
import time

DISQUES = {
    "NUMERO_SERIE_WD": ("WD Red Plus 4 To", "Données"),
    "NUMERO_SERIE_BARRACUDA": ("Barracuda 2 To", "Copie photos"),
    "NUMERO_SERIE_SSD": ("Kingston A400", "Système"),
}
# Endurance garantie par le fabricant (To ecrits, ou "TBW") : seulement pour les SSD
ENDURANCE_TO = {"NUMERO_SERIE_SSD": 160}  # Kingston A400 480 Go : 160 To
SORTIE = "/var/lib/homecloud/smart.json"

liste = json.loads(subprocess.run(["lsblk", "-dJo", "NAME,SERIAL"],
                                  capture_output=True, text=True).stdout)
resultat = []
for b in liste.get("blockdevices", []):
    serie = (b.get("serial") or "").strip()
    if serie not in DISQUES:
        continue
    nom, role = DISQUES[serie]
    r = subprocess.run(["smartctl", "-j", "-a", "/dev/" + b["name"]], capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
    except ValueError:
        continue
    attrs = {a["id"]: a for a in d.get("ata_smart_attributes", {}).get("table", [])}

    def brut(i):
        return attrs[i]["raw"]["value"] if i in attrs else None

    resultat.append({
        "nom": nom, "role": role, "serie": serie,
        "sain": d.get("smart_status", {}).get("passed"),
        "temperature": d.get("temperature", {}).get("current"),
        "heures": d.get("power_on_time", {}).get("hours"),
        "realloues": brut(5), "en_attente": brut(197),
        "incorrigibles": brut(198), "crc": brut(199),
        "vie_ssd": attrs[231]["value"] if 231 in attrs else None,
        # Attribut 241 = volume ecrit en Gio sur ce SSD (sur un disque dur Seagate il compte autre chose)
        "ecrits_gio": brut(241) if serie in ENDURANCE_TO else None,
        "endurance_to": ENDURANCE_TO.get(serie),
    })

os.makedirs(os.path.dirname(SORTIE), exist_ok=True)
tmp = SORTIE + ".tmp"
with open(tmp, "w") as f:
    json.dump({"date": time.time(), "disques": resultat}, f)
os.chmod(tmp, 0o644)
os.replace(tmp, SORTIE)
print(f"{len(resultat)} disque(s) releve(s)")
