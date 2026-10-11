#!/bin/bash
# =====================================================================
# Home Cloud - installation de l'ecran de supervision (partie donnees)
#  - collecteur de mesures : /opt/supervision/collecteur.py (127.0.0.1:8088)
#  - page de l'ecran       : /opt/supervision/web/index.html
#  - releve SMART          : /usr/local/sbin/releve-smart.py (toutes les 10 min)
#  - acces Proxmox en LECTURE SEULE (role PVEAuditor) par jeton d'API
# =====================================================================
set -euo pipefail

JELLYFIN_URL="http://192.168.1.27:8096"
INTERFACE="nic0"
NOEUD="serveur"

if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then echo "ERREUR : interface $INTERFACE introuvable."; exit 1; fi

echo "=== 1. Cle d'API Jellyfin ==="
read -r -s -p "Colle la cle d'API Jellyfin (nom 'ecran') puis Entree : " JF_CLE < /dev/tty; echo
if [ -z "$JF_CLE" ]; then echo "ERREUR : cle vide."; exit 1; fi
if curl -s -o /dev/null -w "%{http_code}" -H "Authorization: MediaBrowser Token=\"$JF_CLE\"" "$JELLYFIN_URL/Items/Counts" | grep -q 200; then
  echo "Cle Jellyfin valide"
else
  echo "ATTENTION : Jellyfin refuse cette cle (on continue, tu pourras la corriger dans /etc/supervision.env)"
fi

echo
echo "=== 2. Utilisateur systeme et dossiers ==="
id supervision >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin supervision
mkdir -p /opt/supervision/web /var/lib/homecloud
chmod 755 /var/lib/homecloud

echo
echo "=== 3. Fichiers du collecteur, de la page et du releve SMART ==="
cat > /opt/supervision/collecteur.py <<'FIN_COLLECTEUR'
#!/usr/bin/env python3
"""Home Cloud - collecteur de mesures pour l'ecran de supervision.

Sert la page /opt/supervision/web/index.html et l'API /api/etat.
N'ecoute que sur 127.0.0.1 : rien n'est expose sur le reseau.
Bibliotheque standard uniquement (aucune dependance a installer).
"""
import glob
import json
import os
import ssl
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ECOUTE = os.environ.get("ECOUTE", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8088"))
INTERFACE = os.environ.get("INTERFACE", "nic0")
NOEUD = os.environ.get("NOEUD", "serveur")
JF_URL = os.environ.get("JELLYFIN_URL", "").rstrip("/")
JF_CLE = os.environ.get("JELLYFIN_CLE", "")
PVE_JETON = os.environ.get("PVE_JETON", "")  # forme : utilisateur@pve!nom=secret
PAGE = os.environ.get("PAGE", "/opt/supervision/web/index.html")
ETAT_DIR = os.environ.get("ETAT_DIR", "/var/lib/homecloud")
DUMP_DIR = os.environ.get("DUMP_DIR", "/mnt/wd/sauvegardes/dump")

DISQUES = [
    ("Données", "WD Red Plus · 4 To", "/mnt/wd"),
    ("Copie des photos", "Barracuda · 2 To", "/mnt/barracuda"),
    ("Système", "Kingston A400 · 480 Go", "/"),
]

# Certificat auto-signe de Proxmox : verification desactivee UNIQUEMENT
# pour l'appel vers 127.0.0.1 (le serveur lui-meme).
CTX_LOCAL = ssl.create_default_context()
CTX_LOCAL.check_hostname = False
CTX_LOCAL.verify_mode = ssl.CERT_NONE

etat = {"pret": False}
verrou = threading.Lock()


def maj(**valeurs):
    with verrou:
        etat.update(valeurs)


# ---------- Mesures rapides (chaque seconde) ----------

def lire_cpu():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    return sum(v), v[3] + v[4]  # total, inactif (idle + iowait)


def lire_reseau():
    with open("/proc/net/dev") as f:
        for ligne in f:
            if ligne.strip().startswith(INTERFACE + ":"):
                c = ligne.split(":", 1)[1].split()
                return int(c[0]), int(c[8])  # octets recus, octets envoyes
    return 0, 0


def lire_memoire():
    m = {}
    with open("/proc/meminfo") as f:
        for ligne in f:
            cle, val = ligne.split(":", 1)
            m[cle] = int(val.split()[0]) * 1024
    total = m["MemTotal"]
    return total, total - m.get("MemAvailable", 0)


def lire_temp_cpu():
    for nom in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            with open(nom) as f:
                if f.read().strip() != "coretemp":
                    continue
            with open(os.path.join(os.path.dirname(nom), "temp1_input")) as f:
                return int(f.read()) / 1000
        except (OSError, ValueError):
            pass
    return None


CPUFREQ = os.environ.get("CPUFREQ", "/sys/devices/system/cpu")


def lire_texte(chemin):
    try:
        with open(chemin) as f:
            return f.read().strip()
    except OSError:
        return None


def lire_frequences():
    """Frequence actuelle de chaque coeur en GHz, plafond autorise, maximum materiel, turbo."""
    coeurs = []
    fichiers = glob.glob(CPUFREQ + "/cpu[0-9]*/cpufreq/scaling_cur_freq")
    for f in sorted(fichiers, key=lambda c: int(c.split("/")[-3][3:])):   # cpu0, cpu1… cpu10 dans l'ordre
        v = lire_texte(f)
        if v and v.isdigit():
            coeurs.append(int(v) / 1e6)              # le noyau donne des kHz
    if not coeurs:                                   # repli si cpufreq est absent
        try:
            with open("/proc/cpuinfo") as f:
                coeurs = [float(l.split(":")[1]) / 1000 for l in f if l.startswith("cpu MHz")]
        except (OSError, ValueError):
            coeurs = []
    if not coeurs:
        return None
    base = CPUFREQ + "/cpu0/cpufreq/"
    materiel = lire_texte(base + "cpuinfo_max_freq")
    plafond = lire_texte(base + "scaling_max_freq")
    no_turbo = lire_texte(CPUFREQ + "/intel_pstate/no_turbo")
    return {
        "moyenne": round(sum(coeurs) / len(coeurs), 2),
        "max": round(max(coeurs), 2),
        "coeurs": [round(c, 2) for c in coeurs],
        "materiel": int(materiel) / 1e6 if materiel and materiel.isdigit() else None,
        "plafond": int(plafond) / 1e6 if plafond and plafond.isdigit() else None,
        "turbo": None if no_turbo is None else no_turbo == "0",
        "gouverneur": lire_texte(base + "scaling_governor"),
    }


def boucle_rapide():
    cpu_prec = lire_cpu()
    net_prec = lire_reseau()
    t_prec = time.time()
    while True:
        time.sleep(1)
        try:
            cpu = lire_cpu()
            net = lire_reseau()
            t = time.time()
            dt = max(t - t_prec, 0.001)
            d_total = cpu[0] - cpu_prec[0]
            d_inactif = cpu[1] - cpu_prec[1]
            charge = 100.0 * (1 - d_inactif / d_total) if d_total > 0 else 0.0
            rx = max(net[0] - net_prec[0], 0) * 8 / dt / 1e6  # Mbit/s
            tx = max(net[1] - net_prec[1], 0) * 8 / dt / 1e6
            mem_total, mem_util = lire_memoire()
            with open("/proc/uptime") as f:
                uptime = float(f.read().split()[0])
            with open("/proc/loadavg") as f:
                charge_moy = [float(x) for x in f.read().split()[:3]]
            maj(cpu=round(charge, 1), reseau_rx=round(rx, 2), reseau_tx=round(tx, 2),
                mem_total=mem_total, mem_util=mem_util, temp_cpu=lire_temp_cpu(), freq=lire_frequences(),
                uptime=uptime, charge_moyenne=charge_moy, horodatage=t, pret=True)
            cpu_prec, net_prec, t_prec = cpu, net, t
        except Exception as e:  # on ne laisse jamais la boucle mourir
            maj(erreur_rapide=str(e)[:200])


# ---------- Mesures lentes (toutes les 15 s) ----------

def get_json(url, entetes=None, contexte=None, delai=4):
    req = urllib.request.Request(url, headers=entetes or {})
    with urllib.request.urlopen(req, timeout=delai, context=contexte) as r:
        return json.loads(r.read().decode())


def lire_disques():
    sortie = []
    for nom, modele, chemin in DISQUES:
        try:
            s = os.statvfs(chemin)
            total = s.f_blocks * s.f_frsize
            libre = s.f_bavail * s.f_frsize
            monte = chemin == "/" or os.path.ismount(chemin)
            sortie.append({"nom": nom, "modele": modele, "chemin": chemin, "monte": monte,
                           "total": total, "libre": libre, "utilise": total - libre})
        except OSError:
            sortie.append({"nom": nom, "modele": modele, "chemin": chemin, "monte": False})
    return sortie


def lire_jellyfin():
    if not (JF_URL and JF_CLE):
        return {"ok": False, "erreur": "non configuré"}
    # En-tete d'authentification moderne (les anciens en-tetes "X-Emby-Token" sont refuses par defaut depuis Jellyfin 10.11+)
    h = {"Authorization": f'MediaBrowser Token="{JF_CLE}"'}
    try:
        c = get_json(JF_URL + "/Items/Counts", h)
        sessions = get_json(JF_URL + "/Sessions?activeWithinSeconds=120", h)
        lectures = []
        for s in sessions:
            item = s.get("NowPlayingItem")
            if not item:
                continue
            ps = s.get("PlayState") or {}
            ti = s.get("TranscodingInfo") or {}
            lectures.append({
                "titre": item.get("Name"), "annee": item.get("ProductionYear"),
                "appareil": s.get("DeviceName"), "client": s.get("Client"),
                "methode": ps.get("PlayMethod"), "pause": ps.get("IsPaused", False),
                "position": (ps.get("PositionTicks") or 0) / 1e7,
                "duree": (item.get("RunTimeTicks") or 0) / 1e7,
                "materiel": ti.get("HardwareAccelerationType"),
            })
        return {"ok": True, "films": c.get("MovieCount", 0), "series": c.get("SeriesCount", 0),
                "episodes": c.get("EpisodeCount", 0), "lectures": lectures}
    except Exception as e:
        return {"ok": False, "erreur": str(e)[:150]}


def lire_proxmox():
    if not PVE_JETON:
        return {"ok": False, "erreur": "non configuré"}
    h = {"Authorization": "PVEAPIToken=" + PVE_JETON}
    base = "https://127.0.0.1:8006/api2/json"
    try:
        invites = []
        for typ in ("lxc", "qemu"):
            for g in get_json(f"{base}/nodes/{NOEUD}/{typ}", h, CTX_LOCAL)["data"]:
                invites.append({"id": int(g["vmid"]), "nom": g.get("name", ""), "type": typ,
                                "statut": g.get("status"), "mem": g.get("mem", 0),
                                "maxmem": g.get("maxmem", 0), "cpu": g.get("cpu", 0)})
        invites.sort(key=lambda g: g["id"])
        version = get_json(f"{base}/version", h, CTX_LOCAL)["data"].get("version", "")
        return {"ok": True, "invites": invites, "version": version}
    except Exception as e:
        return {"ok": False, "erreur": str(e)[:150]}


def lire_tailscale():
    try:
        r = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5)
        d = json.loads(r.stdout)
        pairs = list((d.get("Peer") or {}).values())
        en_ligne = sum(1 for p in pairs if p.get("Online")) + 1
        return {"ok": d.get("BackendState") == "Running", "en_ligne": en_ligne, "total": len(pairs) + 1}
    except Exception as e:
        return {"ok": False, "erreur": str(e)[:150]}


def lire_smart():
    try:
        with open(os.path.join(ETAT_DIR, "smart.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"date": None, "disques": []}


def lire_copie():
    try:
        with open(os.path.join(ETAT_DIR, "copie-photos.statut")) as f:
            texte = f.read().strip()
        return {"ok": texte.startswith("OK"), "texte": texte}
    except OSError:
        return {"ok": False, "texte": "aucune copie pour l'instant"}


def lire_sauvegardes():
    fichiers = [f for f in glob.glob(os.path.join(DUMP_DIR, "vzdump-*"))
                if f.endswith((".zst", ".gz", ".lzo", ".tar", ".vma"))]
    if not fichiers:
        return {"ok": False, "nombre": 0, "derniere": None}
    derniere = max(os.path.getmtime(f) for f in fichiers)
    return {"ok": time.time() - derniere < 36 * 3600, "nombre": len(fichiers), "derniere": derniere}


def boucle_lente():
    while True:
        try:
            maj(disques=lire_disques(), jellyfin=lire_jellyfin(), proxmox=lire_proxmox(),
                tailscale=lire_tailscale(), smart=lire_smart(), copie=lire_copie(),
                sauvegardes=lire_sauvegardes())
        except Exception as e:
            maj(erreur_lente=str(e)[:200])
        time.sleep(15)


# ---------- Serveur web ----------

class Gestionnaire(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/etat"):
            with verrou:
                corps = json.dumps(etat).encode()
            typ = "application/json"
        elif self.path in ("/", "/index.html"):
            try:
                with open(PAGE, "rb") as f:
                    corps = f.read()
            except OSError:
                corps = "Page absente : installe /opt/supervision/web/index.html".encode()
            typ = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):
        pass  # pas de journal pour chaque requete


if __name__ == "__main__":
    threading.Thread(target=boucle_rapide, daemon=True).start()
    threading.Thread(target=boucle_lente, daemon=True).start()
    ThreadingHTTPServer((ECOUTE, PORT), Gestionnaire).serve_forever()
FIN_COLLECTEUR
cat > /usr/local/sbin/releve-smart.py <<'FIN_SMART'
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
FIN_SMART
cat > /opt/supervision/web/index.html <<'FIN_PAGE'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Salle de contrôle du serveur</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --fond:#05080C; --scene:#070B10; --panneau:#0D141C; --bord:#1A2633; --ligne:#131D27;
  --texte:#D6E2EC; --doux:#9FB2C3; --sourd:#7F93A6; --eteint:#16212C;
  --accent:#36C5E6; --orange:#F2A33A; --vert:#43C08A; --rouge:#F0605A;
  --mono:'JetBrains Mono',ui-monospace,monospace; --sans:'IBM Plex Sans',system-ui,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--fond);overflow:hidden;cursor:none}
#scene{position:absolute;top:0;left:0;width:1920px;height:1080px;transform-origin:0 0;padding:28px;
  background:var(--scene);color:var(--texte);font-family:var(--sans);
  display:grid;grid-template-columns:repeat(4,minmax(0,1fr));grid-template-rows:64px 168px minmax(0,1fr) minmax(0,1fr);gap:18px}
.mono{font-family:var(--mono)}
.panneau{background:var(--panneau);border:1px solid var(--bord);border-radius:10px;padding:20px 22px;display:flex;flex-direction:column;min-width:0;min-height:0}
.titre{font-family:var(--mono);font-size:12px;letter-spacing:.16em;text-transform:uppercase;color:var(--sourd)}
.large{grid-column:span 2}
header{grid-column:1/-1;display:flex;align-items:center;justify-content:space-between;gap:24px;padding:0 6px;border-bottom:1px solid #142029}
.pastille{display:flex;align-items:center;gap:10px;padding:10px 18px;border-radius:999px;border:1px solid}
.point{width:10px;height:10px;border-radius:50%;flex:none}
.ok{color:#8FE3BC;background:rgba(67,192,138,.10);border-color:rgba(67,192,138,.35)}
.ok .point,.point.ok{background:var(--vert);box-shadow:0 0 12px var(--vert)}
.alerte{color:#F7C27A;background:rgba(242,163,58,.10);border-color:rgba(242,163,58,.40)}
.alerte .point,.point.alerte{background:var(--orange);box-shadow:0 0 12px var(--orange)}
.panne{color:#F7A29E;background:rgba(240,96,90,.10);border-color:rgba(240,96,90,.45)}
.panne .point,.point.panne{background:var(--rouge);box-shadow:0 0 12px var(--rouge)}
.point.eteint{background:#3A4A5A;box-shadow:none}
.kpi{justify-content:space-between}
.kpi .valeur{font-family:var(--mono);font-size:52px;font-weight:700;line-height:1;color:var(--accent)}
.kpi .unite{font-family:var(--mono);font-size:18px;color:var(--doux)}
.kpi .sous{margin-left:auto;font-size:13px;color:var(--sourd)}
.segments{display:flex;gap:3px}
.segments span{flex:1;height:10px;border-radius:2px;background:var(--eteint)}
svg.courbe{width:100%;flex:1 1 0;min-height:0;height:auto;display:block}
.plafond{stroke:#F2A33A;stroke-width:1.5;stroke-dasharray:6 5;vector-effect:non-scaling-stroke}
.grille{stroke:#17222D;stroke-width:1;vector-effect:non-scaling-stroke}
.aire{fill-opacity:.14;stroke:none}
.trait{fill:none;stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round}
.barre{height:12px;border-radius:3px;background:var(--eteint);overflow:hidden}
.barre div{height:12px;border-radius:3px;background:var(--accent);transition:width .6s}
.ligne{display:flex;align-items:center;gap:12px;padding:9px 0;border-bottom:1px solid var(--ligne)}
.droite{margin-left:auto;font-family:var(--mono);font-size:13px;color:var(--sourd)}
table{width:100%;border-collapse:collapse}
th{font-family:var(--mono);font-size:12px;font-weight:400;color:var(--sourd);text-align:left;padding:0 6px 8px;border-bottom:1px solid var(--bord)}
td{padding:10px 6px;border-bottom:1px solid var(--ligne);font-size:14px;color:var(--doux)}
td:first-child{font-size:16px;font-weight:600;color:var(--texte)}
.etiquette{display:inline-block;font-size:13px;font-weight:500;padding:5px 12px;border-radius:999px;border:1px solid}
#bandeau{position:absolute;left:50%;top:84px;transform:translateX(-50%);padding:8px 18px;border-radius:8px;display:none;z-index:2}
</style>
</head>
<body>
<div id="scene">

<header>
  <div style="display:flex;align-items:center;gap:16px">
    <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#36C5E6" stroke-width="1.6" aria-hidden="true"><rect x="3" y="3" width="18" height="7" rx="1.5"/><rect x="3" y="14" width="18" height="7" rx="1.5"/><line x1="7" y1="6.5" x2="7.01" y2="6.5"/><line x1="7" y1="17.5" x2="7.01" y2="17.5"/></svg>
    <div style="display:flex;flex-direction:column;gap:4px">
      <div class="mono" style="font-size:22px;font-weight:700;letter-spacing:.18em">SERVEUR</div>
      <div class="mono" id="ident" style="font-size:13px;color:var(--sourd)">serveur.home.arpa · 192.168.1.33</div>
    </div>
  </div>
  <div class="pastille ok" id="global"><span class="point"></span><span id="global-texte" style="font-size:15px;font-weight:500">Connexion…</span></div>
  <div style="display:flex;align-items:center;gap:28px">
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">
      <div id="date" style="font-size:14px;color:var(--sourd)"></div>
      <div class="mono" id="meteo" style="font-size:13px;color:var(--sourd)">Laval</div>
    </div>
    <div class="mono" id="horloge" style="font-size:40px;font-weight:600;color:var(--accent);letter-spacing:.04em">--:--:--</div>
  </div>
</header>
<div id="bandeau" class="panne mono">Données indisponibles : le collecteur ne répond pas</div>

<section class="panneau kpi" id="k-cpu"><div class="titre">Processeur</div>
  <div style="display:flex;align-items:baseline;gap:10px"><span class="valeur">--</span><span class="unite">%</span><span class="sous" id="cpu-ghz">i5-9500 · -- GHz</span></div>
  <div class="segments"></div></section>
<section class="panneau kpi" id="k-ram"><div class="titre">Mémoire</div>
  <div style="display:flex;align-items:baseline;gap:10px"><span class="valeur">--</span><span class="unite">/ 16 Go</span><span class="sous"></span></div>
  <div class="segments"></div></section>
<section class="panneau kpi" id="k-temp"><div class="titre">Température CPU</div>
  <div style="display:flex;align-items:baseline;gap:10px"><span class="valeur">--</span><span class="unite">°C</span><span class="sous">alerte à 80 °C</span></div>
  <div class="segments"></div></section>
<section class="panneau kpi" id="k-net"><div class="titre">Sortie réseau</div>
  <div style="display:flex;align-items:baseline;gap:10px"><span class="valeur" style="color:var(--orange)">--</span><span class="unite">Mbit/s</span><span class="sous"></span></div>
  <div class="segments"></div></section>

<section class="panneau large" style="gap:8px">
  <div style="display:flex;justify-content:space-between;align-items:center"><div class="titre">Activité · 2 dernières minutes</div><div class="mono" style="font-size:12px;color:var(--sourd)">mesure toutes les 2 secondes</div></div>
  <div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-size:14px;color:var(--doux)">Charge processeur</span><span class="mono" id="cpu-txt" style="font-size:16px;color:var(--accent)">-- %</span></div>
  <svg class="courbe" viewBox="0 0 600 100" preserveAspectRatio="none"><line class="grille" x1="0" y1="25" x2="600" y2="25"/><line class="grille" x1="0" y1="50" x2="600" y2="50"/><line class="grille" x1="0" y1="75" x2="600" y2="75"/><polygon class="aire" id="cpu-aire" fill="#36C5E6"/><polyline class="trait" id="cpu-trait" stroke="#36C5E6"/></svg>
  <div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-size:14px;color:var(--doux)">Fréquence processeur (moyenne des cœurs) · <span id="freq-info" class="mono">--</span></span><span class="mono" id="freq-txt" style="font-size:16px;color:var(--vert)">-- GHz</span></div>
  <svg class="courbe" viewBox="0 0 600 100" preserveAspectRatio="none"><line class="grille" x1="0" y1="25" x2="600" y2="25"/><line class="grille" x1="0" y1="50" x2="600" y2="50"/><line class="grille" x1="0" y1="75" x2="600" y2="75"/><line class="plafond" id="freq-plafond" x1="0" x2="600" y1="-10" y2="-10" style="display:none"/><polygon class="aire" id="freq-aire" fill="#43C08A"/><polyline class="trait" id="freq-trait" stroke="#43C08A"/></svg>
  <div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-size:14px;color:var(--doux)">Sortie réseau (flux vers l’extérieur) · <span id="net-echelle" class="mono">échelle 10 Mbit/s</span></span><span class="mono" id="net-txt" style="font-size:16px;color:var(--orange)">-- Mbit/s</span></div>
  <svg class="courbe" viewBox="0 0 600 100" preserveAspectRatio="none"><line class="grille" x1="0" y1="25" x2="600" y2="25"/><line class="grille" x1="0" y1="50" x2="600" y2="50"/><line class="grille" x1="0" y1="75" x2="600" y2="75"/><polygon class="aire" id="net-aire" fill="#F2A33A"/><polyline class="trait" id="net-trait" stroke="#F2A33A"/></svg>
</section>

<section class="panneau" style="gap:18px"><div class="titre">Stockage</div><div id="disques" style="display:flex;flex-direction:column;gap:18px"></div></section>

<section class="panneau" style="gap:16px"><div class="titre">Jellyfin · médiathèque</div>
  <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px">
    <div style="display:flex;flex-direction:column;gap:4px;padding:12px 14px;border-radius:8px;background:#111B25"><span class="mono" id="jf-films" style="font-size:40px;font-weight:700;line-height:1">--</span><span style="font-size:13px;color:var(--sourd)">films</span></div>
    <div style="display:flex;flex-direction:column;gap:4px;padding:12px 14px;border-radius:8px;background:#111B25"><span class="mono" id="jf-series" style="font-size:40px;font-weight:700;line-height:1">--</span><span style="font-size:13px;color:var(--sourd)">séries</span></div>
  </div>
  <div id="jf-lecture" style="display:flex;flex-direction:column;gap:8px;padding:14px;border-radius:8px;border:1px solid #22313F"></div>
</section>

<section class="panneau large" style="gap:14px">
  <div style="display:flex;justify-content:space-between;align-items:center"><div class="titre">Santé des disques · SMART</div><div class="mono" id="smart-date" style="font-size:12px;color:var(--sourd)"></div></div>
  <table><thead><tr><th>DISQUE</th><th>RÔLE</th><th>TEMP.</th><th>HEURES</th><th>INDICATEUR CLÉ</th><th>ÉTAT</th></tr></thead><tbody id="smart"></tbody></table>
</section>

<section class="panneau" style="gap:2px"><div class="titre" style="margin-bottom:8px">Services</div><div id="services"></div></section>

<section class="panneau" style="gap:2px"><div class="titre" style="margin-bottom:8px">Conteneurs Proxmox</div><div id="invites"></div></section>

</div>
<script>
"use strict";
const POINTS = 60;               // 60 mesures x 2 s = 2 minutes
const histCpu = [], histNet = [], histFreq = [];
const $ = (id) => document.getElementById(id);

// ---------- Outils ----------
function el(tag, props, enfants) {          // construit le DOM sans innerHTML (textes sûrs)
  const e = document.createElement(tag);
  if (props) for (const [k, v] of Object.entries(props)) {
    if (k === "style") e.style.cssText = v; else if (k === "class") e.className = v; else e[k] = v;
  }
  for (const c of [].concat(enfants || [])) e.append(c);
  return e;
}
function vider(e, enfants) { e.replaceChildren(...enfants); }
const fr = (n, d = 0) => Number(n).toLocaleString("fr-FR", { minimumFractionDigits: d, maximumFractionDigits: d });
function taille(o) {
  const u = ["o", "Ko", "Mo", "Go", "To"]; let i = 0;
  while (o >= 1000 && i < u.length - 1) { o /= 1000; i++; }
  return fr(o, o < 10 && i > 2 ? 1 : 0) + " " + u[i];
}
function duree(s) {
  s = Math.floor(s); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
  return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(sec).padStart(2, "0");
}
function depuis(t) {
  const j = Math.floor(t / 86400), h = Math.floor(t % 86400 / 3600), m = Math.floor(t % 3600 / 60);
  return j ? `${j} j ${h} h` : h ? `${h} h ${m} min` : `${m} min`;
}
function quand(texte) {                     // "OK 2026-10-08 12:16 : ..." -> "réussie · auj. 12:16"
  if (!texte) return "--";
  const m = texte.match(/^(OK|ECHEC) (\d{4})-(\d\d)-(\d\d) (\d\d:\d\d)/);
  if (!m) return texte.slice(0, 30);
  const auj = new Date().toLocaleDateString("sv-SE") === `${m[2]}-${m[3]}-${m[4]}`;
  return (m[1] === "OK" ? "réussie · " : "ÉCHEC · ") + (auj ? "auj. " : `${m[4]}/${m[3]} `) + m[5];
}
function heure(ts) { return new Date(ts * 1000).toLocaleString("fr-FR", { weekday: "short", hour: "2-digit", minute: "2-digit" }); }

// ---------- Mise à l'échelle plein écran ----------
function ajuster() {
  const s = Math.min(innerWidth / 1920, innerHeight / 1080);
  $("scene").style.transform = `translate(${(innerWidth - 1920 * s) / 2}px,${(innerHeight - 1080 * s) / 2}px) scale(${s})`;
}
addEventListener("resize", ajuster); ajuster();

// ---------- Indicateurs principaux ----------
document.querySelectorAll(".segments").forEach(b => { for (let i = 0; i < 24; i++) b.append(el("span")); });
function kpi(id, valeur, pct, couleur, sous) {
  const b = $(id);
  b.querySelector(".valeur").textContent = valeur;
  if (sous !== undefined) b.querySelector(".sous").textContent = sous;
  b.querySelectorAll(".segments span").forEach((s, i) => {
    const allume = (i + 0.5) / 24 * 100 <= pct;
    s.style.background = allume ? (i >= 19 ? "var(--orange)" : couleur) : "var(--eteint)";
  });
}
function tracer(hist, max, idAire, idTrait) {
  const n = POINTS, W = 600, H = 100;
  const pts = hist.map((v, i) => `${((n - hist.length + i) * W / (n - 1)).toFixed(1)},${(H - Math.min(v, max) / max * (H - 6) - 3).toFixed(1)}`);
  $(idTrait).setAttribute("points", pts.join(" "));
  if (pts.length) {
    const debut = ((n - hist.length) * W / (n - 1)).toFixed(1);
    $(idAire).setAttribute("points", pts.join(" ") + ` ${W},${H} ${debut},${H}`);
  }
}

// ---------- Rendu ----------
function afficher(e) {
  // Processeur, mémoire, température, réseau
  kpi("k-cpu", fr(e.cpu), e.cpu, "var(--accent)");
  const GIO = 1024 ** 3, memGo = e.mem_util / GIO, memPct = e.mem_util / e.mem_total * 100;
  $("k-ram").querySelector(".unite").textContent = "/ " + Math.ceil(e.mem_total / GIO) + " Go";
  kpi("k-ram", fr(memGo, 1), memPct, "var(--accent)", fr(memPct) + " % utilisée");
  if (e.temp_cpu != null) kpi("k-temp", fr(e.temp_cpu), e.temp_cpu, e.temp_cpu > 70 ? "var(--orange)" : "var(--accent)");
  kpi("k-net", fr(e.reseau_tx, e.reseau_tx < 10 ? 1 : 0), Math.min(e.reseau_tx, 100), "var(--orange)", "reçu : " + fr(e.reseau_rx, 1) + " Mbit/s");

  const fq = e.freq || null;
  histCpu.push(e.cpu); histNet.push(e.reseau_tx); histFreq.push(fq ? fq.moyenne : 0);
  if (histCpu.length > POINTS) { histCpu.shift(); histNet.shift(); histFreq.shift(); }
  tracer(histCpu, 100, "cpu-aire", "cpu-trait");
  const maxNet = Math.max(10, Math.ceil(Math.max(...histNet) * 1.2 / 10) * 10);
  tracer(histNet, maxNet, "net-aire", "net-trait");
  $("cpu-txt").textContent = fr(e.cpu) + " %";
  $("net-txt").textContent = fr(e.reseau_tx, 1) + " Mbit/s";
  $("net-echelle").textContent = "échelle " + maxNet + " Mbit/s";

  // Fréquence : échelle = maximum matériel (turbo compris), ligne pointillée = plafond si bridé
  if (fq) {
    const maxGhz = Math.max(fq.materiel || 0, ...histFreq, 1);
    tracer(histFreq, maxGhz, "freq-aire", "freq-trait");
    $("freq-txt").textContent = fr(fq.moyenne, 2) + " GHz";
    $("cpu-ghz").textContent = "i5-9500 · " + fr(fq.moyenne, 2) + " GHz";
    const bride = fq.plafond && fq.materiel && fq.plafond < fq.materiel - 0.05;
    const ligne = $("freq-plafond");
    ligne.style.display = bride ? "" : "none";
    if (bride) { const y = (100 - fq.plafond / maxGhz * 94 - 3).toFixed(1); ligne.setAttribute("y1", y); ligne.setAttribute("y2", y); }
    const infos = ["cœur le plus rapide " + fr(fq.max, 2) + " GHz"];
    if (bride) infos.push("bridé à " + fr(fq.plafond, 1) + " GHz");
    else if (fq.materiel) infos.push("max " + fr(fq.materiel, 1) + " GHz");
    if (fq.turbo === false) infos.push("turbo coupé");
    $("freq-info").textContent = infos.join(" · ");
  }

  // En-tête
  const pve = e.proxmox || {};
  $("ident").textContent = "serveur.home.arpa · 192.168.1.33" + (pve.version ? " · Proxmox VE " + pve.version : "") + " · en service depuis " + depuis(e.uptime || 0);

  // Stockage
  if (e.disques) vider($("disques"), e.disques.map(d => {
    if (!d.monte) return el("div", { style: "color:var(--rouge);font-size:15px" }, d.nom + " : NON MONTÉ");
    const pct = d.utilise / d.total * 100;
    return el("div", { style: "display:flex;flex-direction:column;gap:8px" }, [
      el("div", { style: "display:flex;justify-content:space-between;align-items:baseline" }, [
        el("span", { style: "font-size:16px;font-weight:600" }, d.nom),
        el("span", { class: "mono", style: "font-size:15px;color:var(--accent)" }, taille(d.libre) + " libres")]),
      el("div", { class: "barre" }, el("div", { style: `width:${Math.max(pct, 0.5)}%` + (pct > 85 ? ";background:var(--orange)" : "") })),
      el("div", { style: "display:flex;justify-content:space-between" }, [
        el("span", { style: "font-size:13px;color:var(--sourd)" }, d.modele),
        el("span", { class: "mono", style: "font-size:13px;color:var(--sourd)" }, taille(d.utilise) + " utilisés · " + fr(pct) + " %")])]);
  }));

  // Jellyfin
  const jf = e.jellyfin || {};
  $("jf-films").textContent = jf.ok ? fr(jf.films) : "--";
  $("jf-series").textContent = jf.ok ? fr(jf.series) : "--";
  const l = (jf.lectures || [])[0];
  if (l) {
    const pct = l.duree ? l.position / l.duree * 100 : 0;
    const mode = l.methode === "Transcode" ? "transcodage" + (l.materiel ? " matériel (" + l.materiel + ")" : "") : l.methode === "DirectPlay" ? "lecture directe" : (l.methode || "");
    vider($("jf-lecture"), [
      el("div", { style: "display:flex;align-items:center;gap:8px" }, [
        el("span", { class: "point " + (l.pause ? "eteint" : "alerte"), style: "width:8px;height:8px" }),
        el("span", { class: "mono", style: "font-size:12px;letter-spacing:.12em;color:var(--orange)" }, l.pause ? "EN PAUSE" : "LECTURE EN COURS"),
        el("span", { class: "mono", style: "margin-left:auto;font-size:12px;color:var(--sourd)" }, (jf.lectures.length > 1 ? "+" + (jf.lectures.length - 1) + " autre(s)" : ""))]),
      el("span", { style: "font-size:18px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, l.titre + (l.annee ? " (" + l.annee + ")" : "")),
      el("span", { style: "font-size:13px;color:var(--sourd)" }, (l.appareil || "") + " · " + mode),
      el("div", { style: "height:6px;border-radius:3px;background:var(--eteint);overflow:hidden" }, el("div", { style: `height:6px;width:${pct}%;background:var(--orange)` })),
      el("span", { class: "mono", style: "font-size:12px;color:var(--sourd)" }, duree(l.position) + " / " + duree(l.duree))]);
  } else {
    vider($("jf-lecture"), [el("span", { style: "font-size:14px;color:var(--sourd)" }, jf.ok ? "Aucune lecture en cours" : "Jellyfin injoignable" + (jf.erreur ? " (" + jf.erreur + ")" : ""))]);
  }

  // SMART
  const sm = e.smart || {};
  $("smart-date").textContent = sm.date ? "relevé : " + heure(sm.date) : "pas encore de relevé";
  vider($("smart"), (sm.disques || []).map(d => {
    let cle, ton, etiq;
    if (d.endurance_to && d.ecrits_gio != null) {   // SSD : volume ecrit / endurance garantie (indicateur objectif)
      const ecritsTo = d.ecrits_gio * 1.073741824 / 1000, usure = ecritsTo / d.endurance_to * 100;
      cle = fr(ecritsTo, 1) + " / " + d.endurance_to + " To écrits · " + fr(usure) + " %";
      ton = usure >= 80 ? "panne" : usure >= 50 ? "alerte" : "ok";
    } else if (d.vie_ssd != null) { cle = "attribut 231 : " + d.vie_ssd; ton = "alerte"; }
    else { cle = (d.realloues ?? "?") + " réalloué(s) · " + (d.en_attente ?? "?") + " en attente"; ton = d.en_attente > 0 ? "panne" : d.realloues > 0 ? "alerte" : "ok"; }
    if (d.sain === false) ton = "panne";
    etiq = { ok: "Sain", alerte: "À surveiller", panne: "Critique" }[ton];
    return el("tr", null, [el("td", null, d.nom), el("td", null, d.role), el("td", { class: "mono" }, d.temperature != null ? d.temperature + " °C" : "--"),
      el("td", { class: "mono" }, d.heures != null ? fr(d.heures) + " h" : "--"), el("td", { class: "mono" }, cle),
      el("td", null, el("span", { class: "etiquette " + ton }, etiq))]);
  }));

  // Services
  const invites = pve.invites || [];
  const partage = invites.find(g => g.id === 101);
  const ts = e.tailscale || {}, cp = e.copie || {}, sv = e.sauvegardes || {};
  const services = [
    ["Proxmox VE", pve.ok, pve.ok ? ":8006" : "API injoignable"],
    ["Partage SMB", partage && partage.statut === "running", partage ? (partage.statut === "running" ? "photos · films" : "arrêté") : "inconnu"],
    ["Jellyfin", jf.ok, jf.ok ? ((jf.lectures || []).length + " lecture(s)") : "injoignable"],
    ["Tailscale", ts.ok, ts.ok ? ts.en_ligne + "/" + ts.total + " en ligne" : "déconnecté"],
    ["Copie des photos", cp.ok, quand(cp.texte)],
    ["Sauvegardes", sv.ok, sv.derniere ? "dernière : " + heure(sv.derniere) : "aucune"],
  ];
  vider($("services"), services.map(([nom, ok, detail]) => el("div", { class: "ligne" }, [
    el("span", { class: "point " + (ok ? "ok" : "panne"), style: "width:9px;height:9px" }),
    el("span", { style: "font-size:15px;font-weight:500" }, nom), el("span", { class: "droite" }, detail)])));
  const enPanne = services.filter(s => !s[1]).length;
  const g = $("global");
  g.className = "pastille " + (enPanne === 0 ? "ok" : enPanne <= 2 ? "alerte" : "panne");
  $("global-texte").textContent = enPanne === 0 ? "Tous les services opérationnels" : enPanne + " service(s) à vérifier";

  // Conteneurs
  vider($("invites"), invites.map(c => el("div", { class: "ligne" }, [
    el("span", { class: "mono", style: "font-size:13px;color:var(--sourd);width:34px" }, String(c.id)),
    el("span", { class: "point " + (c.statut === "running" ? "ok" : "eteint"), style: "width:8px;height:8px" }),
    el("span", { style: "font-size:15px;font-weight:500" + (c.statut === "running" ? "" : ";color:var(--sourd)") }, c.nom),
    el("span", { class: "droite" }, c.statut === "running" ? fr(c.mem / 1e9, 1) + " / " + fr(c.maxmem / 1e9, 1) + " Go" : "arrêté")])));
  if (!pve.ok) vider($("invites"), [el("span", { style: "font-size:14px;color:var(--sourd)" }, "API Proxmox injoignable" + (pve.erreur ? " : " + pve.erreur : ""))]);
}

async function rafraichir() {
  try {
    const r = await fetch("/api/etat", { cache: "no-store" });
    const e = await r.json();
    $("bandeau").style.display = "none";
    if (e.pret) afficher(e);
  } catch (err) {
    $("bandeau").style.display = "block";
  }
}
rafraichir(); setInterval(rafraichir, 2000);

// ---------- Horloge ----------
function horloge() {
  const d = new Date();
  $("horloge").textContent = d.toLocaleTimeString("fr-FR", { timeZone: "Europe/Paris" });
  const j = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", timeZone: "Europe/Paris" });
  $("date").textContent = j.charAt(0).toUpperCase() + j.slice(1);
}
horloge(); setInterval(horloge, 1000);

// ---------- Météo à Laval (Open-Meteo, sans clé) ----------
const CIEL = [[0, "ciel dégagé"], [3, "nuageux"], [48, "brouillard"], [57, "bruine"], [67, "pluie"], [77, "neige"], [82, "averses"], [86, "averses de neige"], [99, "orage"]];
async function meteo() {
  try {
    const r = await fetch("https://api.open-meteo.com/v1/forecast?latitude=48.07&longitude=-0.77&current=temperature_2m,weather_code&timezone=Europe%2FParis");
    const m = (await r.json()).current;
    const ciel = (CIEL.find(([max]) => m.weather_code <= max) || [0, ""])[1];
    $("meteo").textContent = `Laval · ${fr(m.temperature_2m)} °C · ${ciel}`;
  } catch (err) { $("meteo").textContent = "Laval · météo indisponible"; }
}
meteo(); setInterval(meteo, 15 * 60 * 1000);
</script>
</body>
</html>
FIN_PAGE
chmod 755 /opt/supervision/collecteur.py /usr/local/sbin/releve-smart.py
chmod 644 /opt/supervision/web/index.html
echo "Fichiers installes"

echo
echo "=== 4. Acces Proxmox en lecture seule (utilisateur supervision@pve, role PVEAuditor) ==="
if ! pveum user list --output-format json | grep -q '"supervision@pve"'; then
  pveum user add supervision@pve --comment "Ecran de supervision (lecture seule)"
fi
pveum acl modify / --users supervision@pve --roles PVEAuditor
pveum user token remove supervision@pve ecran >/dev/null 2>&1 || true
SECRET=$(pveum user token add supervision@pve ecran --privsep 0 --comment "Collecteur de l'ecran" --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')
echo "Jeton cree : supervision@pve!ecran (lecture seule)"

echo
echo "=== 5. Fichier de configuration protege (/etc/supervision.env) ==="
umask 077
cat > /etc/supervision.env <<FIN_ENV
INTERFACE=$INTERFACE
NOEUD=$NOEUD
JELLYFIN_URL=$JELLYFIN_URL
JELLYFIN_CLE=$JF_CLE
PVE_JETON=supervision@pve!ecran=$SECRET
FIN_ENV
umask 022
chown root:supervision /etc/supervision.env
chmod 640 /etc/supervision.env
unset JF_CLE SECRET
ls -l /etc/supervision.env

echo
echo "=== 6. Services systemd ==="
cat > /etc/systemd/system/supervision.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - collecteur de l'ecran de supervision
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
User=supervision
Group=supervision
EnvironmentFile=/etc/supervision.env
ExecStart=/usr/bin/python3 /opt/supervision/collecteur.py
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
FIN_UNITE

cat > /etc/systemd/system/releve-smart.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - releve SMART des disques pour l'ecran

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/releve-smart.py
Nice=19
FIN_UNITE

cat > /etc/systemd/system/releve-smart.timer <<'FIN_UNITE'
[Unit]
Description=Releve SMART toutes les 10 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
FIN_UNITE

systemctl daemon-reload
systemctl enable --now releve-smart.timer
systemctl start releve-smart.service
systemctl enable supervision.service
systemctl restart supervision.service

echo
echo "=== 7. Verification (20 secondes) ==="
sleep 20
echo -n "Collecteur : "; systemctl is-active supervision
python3 - <<'FIN_VERIF'
import json, urllib.request
e = json.load(urllib.request.urlopen("http://127.0.0.1:8088/api/etat", timeout=5))
def ok(v):
    return "OK " if v else "NON"
jf, px, ts = e.get("jellyfin", {}), e.get("proxmox", {}), e.get("tailscale", {})
sm, cp, sv = e.get("smart", {}), e.get("copie", {}), e.get("sauvegardes", {})
print(f"Processeur  : {e.get('cpu')} %   Memoire : {e.get('mem_util', 0) / 2**30:.1f} Gio   Temp CPU : {e.get('temp_cpu')} C")
print(f"Reseau      : {e.get('reseau_tx')} Mbit/s envoyes")
for d in e.get("disques", []):
    print(f"Disque      : {d['nom']:<18} {'monte' if d.get('monte') else 'NON MONTE'}")
print(f"[{ok(jf.get('ok'))}] Jellyfin    : {jf.get('films', jf.get('erreur'))} film(s)")
print(f"[{ok(px.get('ok'))}] Proxmox     : {len(px.get('invites', [])) if px.get('ok') else px.get('erreur')} invite(s), version {px.get('version', '?')}")
print(f"[{ok(ts.get('ok'))}] Tailscale   : {ts.get('en_ligne', ts.get('erreur'))} appareil(s) en ligne")
print(f"[{ok(sm.get('disques'))}] SMART       : {len(sm.get('disques', []))} disque(s)")
print(f"[{ok(cp.get('ok'))}] Copie       : {cp.get('texte')}")
print(f"[{ok(sv.get('ok'))}] Sauvegardes : {sv.get('nombre')} fichier(s)")
FIN_VERIF
echo
echo "TERMINE. La page est servie sur http://127.0.0.1:8088 (uniquement depuis le serveur)."
