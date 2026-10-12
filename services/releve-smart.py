#!/usr/bin/env python3
"""Home Cloud - disk SMART readout (run by root every 10 min).
Writes /var/lib/homecloud/smart.json, read by the dashboard collector."""
import json
import os
import subprocess
import time

DISQUES = {
    "DISK_SERIAL_WD": ("WD Red Plus 4 To", "Données"),
    "DISK_SERIAL_BARRACUDA": ("Barracuda 2 To", "Copie photos"),
    "DISK_SERIAL_SSD": ("Kingston A400", "Système"),
}
# Manufacturer-rated endurance (TB written, or "TBW"): SSDs only
ENDURANCE_TO = {"DISK_SERIAL_SSD": 160}  # Kingston A400 480 GB: 160 TB
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
        # Attribute 241 = GiB written on this SSD (on a Seagate hard drive it counts something else)
        "ecrits_gio": brut(241) if serie in ENDURANCE_TO else None,
        "endurance_to": ENDURANCE_TO.get(serie),
    })

os.makedirs(os.path.dirname(SORTIE), exist_ok=True)
tmp = SORTIE + ".tmp"
with open(tmp, "w") as f:
    json.dump({"date": time.time(), "disques": resultat}, f)
os.chmod(tmp, 0o644)
os.replace(tmp, SORTIE)
print(f"{len(resultat)} disk(s) read")
