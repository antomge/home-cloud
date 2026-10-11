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


def lire_finops():
    try:
        with open(os.path.join(ETAT_DIR, "finops.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def boucle_lente():
    while True:
        try:
            maj(disques=lire_disques(), jellyfin=lire_jellyfin(), proxmox=lire_proxmox(),
                tailscale=lire_tailscale(), smart=lire_smart(), copie=lire_copie(),
                sauvegardes=lire_sauvegardes(), finops=lire_finops())
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
        elif self.path in ("/liens", "/links"):
            try:
                with open(os.path.join(os.path.dirname(PAGE), "liens.html"), "rb") as f:
                    corps = f.read()
            except OSError:
                corps = "Page des liens absente".encode()
            typ = "text/html; charset=utf-8"
        elif self.path in ("/finops", "/finops.html"):
            try:
                with open(os.path.join(os.path.dirname(PAGE), "finops.html"), "rb") as f:
                    corps = f.read()
            except OSError:
                corps = "Page FinOps absente".encode()
            typ = "text/html; charset=utf-8"
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
