#!/bin/bash
# Home Cloud - tableau de bord FinOps : mesure de l'energie, cout par service, comparaison Azure
#   /usr/local/sbin/finops-releve.py   chaque minute (root)  -> /var/lib/homecloud/finops.json
#   /usr/local/sbin/finops-azure.py    chaque semaine        -> /var/lib/homecloud/azure-prix.json
#   /etc/homecloud/finops.json         hypotheses (prix du kWh, materiel, equivalent Azure...)
#   page : https://tableau.maison.exemple.fr/finops
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi

echo "=== 1. Compteurs d'energie du processeur (RAPL) ==="
modprobe intel_rapl_msr 2>/dev/null || true
if [ -r /sys/class/powercap/intel-rapl:0/energy_uj ]; then
  echo "RAPL disponible : $(cat /sys/class/powercap/intel-rapl:0/name)"
  echo intel_rapl_msr > /etc/modules-load.d/rapl.conf
else
  echo "RAPL absent : la puissance du processeur sera ESTIMEE d'apres sa charge."
fi

echo
echo "=== 2. Fichiers ==="
mkdir -p /etc/homecloud /var/lib/homecloud
if [ -f /etc/homecloud/finops.json ]; then
  echo "Configuration existante conservee : /etc/homecloud/finops.json"
else
cat > /etc/homecloud/finops.json <<'FIN_CONF'
{
  "prix_kwh_eur": 0.2001,
  "source_prix": "Tarif Bleu EDF option Base (6 kVA), en vigueur depuis le 1er août 2026",
  "autres_composants_w": 14,
  "detail_autres": "WD Red Plus ≈ 4,5 W, Barracuda ≈ 4,5 W, SSD ≈ 0,5 W, carte mère + mémoire + ventilateurs ≈ 4,5 W (estimation à confronter à une prise wattmètre)",
  "rendement_alimentation": 0.85,
  "memoire_reservee_hote_mo": 2048,
  "estimation_sans_rapl": {"repos_w": 5, "max_w": 65},
  "materiel": [
    {"nom": "Processeur Intel Core i5-9500 (reconditionné)", "prix": 99.99},
    {"nom": "Disque WD Red Plus 4 To", "prix": 224.98},
    {"nom": "Switch TP-Link TL-SG605E", "prix": 18.99}
  ],
  "amortissement_mois": 36,
  "domaine_eur_an": null,
  "azure": {
    "region": "francecentral",
    "region_libelle": "France Centre",
    "vm": "Standard_B4ms",
    "vm_libelle": "B4ms (4 vCPU, 16 Go)",
    "disque": "S50 LRS",
    "disque_libelle": "Disque HDD standard S50 (4 To)"
  }
}
FIN_CONF
  echo "Configuration creee : /etc/homecloud/finops.json"
fi
cat > /usr/local/sbin/finops-releve.py <<'FIN_RELEVE'
#!/usr/bin/env python3
"""Home Cloud - releve FinOps (lance chaque minute par un minuteur systemd, en root).

1. Mesure l'energie du processeur avec ses compteurs RAPL (Intel), en joules.
2. Estime la puissance a la prise : (processeur + autres composants) / rendement alimentation.
3. Impute l'energie de chaque minute aux services (showback) :
   - part VARIABLE (processeur au-dessus du repos) -> au prorata du temps processeur consomme ;
   - part FIXE (repos + disques + carte mere) -> au prorata de la memoire reservee,
     comme une capacite reservee dans le cloud.
4. Cumule par jour, puis ecrit une synthese lisible par le tableau de bord.
"""
import datetime
import glob
import json
import os
import re
import time

CONF = os.environ.get("FINOPS_CONF", "/etc/homecloud/finops.json")
ETAT_DIR = os.environ.get("ETAT_DIR", "/var/lib/homecloud")
RAPL = os.environ.get("RAPL_DIR", "/sys/class/powercap")
CGROUP = os.environ.get("CGROUP_LXC", "/sys/fs/cgroup/lxc")
PVE_LXC = os.environ.get("PVE_LXC", "/etc/pve/lxc")
PROC_STAT = os.environ.get("PROC_STAT", "/proc/stat")
MAINTENANT = float(os.environ.get("FINOPS_MAINTENANT", "0")) or None   # uniquement pour les tests

ETAT = os.path.join(ETAT_DIR, "finops-etat.json")
SORTIE = os.path.join(ETAT_DIR, "finops.json")
AZURE = os.path.join(ETAT_DIR, "azure-prix.json")
HOTE = "Proxmox (hôte)"
JOURS_GARDES = 400


def lire(chemin, defaut=None):
    try:
        with open(chemin) as f:
            return f.read().strip()
    except OSError:
        return defaut


def lire_json(chemin, defaut):
    try:
        with open(chemin) as f:
            return json.load(f)
    except (OSError, ValueError):
        return defaut


def ecrire_json(chemin, donnees):
    tmp = chemin + ".tmp"
    with open(tmp, "w") as f:
        json.dump(donnees, f, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, chemin)


# ---------- Mesures ----------

def lire_rapl():
    """Compteurs d'energie des processeurs (paquets), en microjoules."""
    paquets = {}
    for d in glob.glob(os.path.join(RAPL, "intel-rapl:*")):
        if not re.search(r"intel-rapl:\d+$", d):
            continue                      # on ignore les sous-domaines (coeurs, graphique...)
        e, m = lire(os.path.join(d, "energy_uj")), lire(os.path.join(d, "max_energy_range_uj"))
        if e and e.isdigit() and m and m.isdigit():
            paquets[os.path.basename(d)] = {"e": int(e), "max": int(m)}
    return paquets


def lire_cpu_total():
    """Temps processeur occupe de toute la machine, en microsecondes."""
    with open(PROC_STAT) as f:
        v = [int(x) for x in f.readline().split()[1:]]
    occupe = sum(v[:8]) - v[3] - v[4]     # tout sauf inactif et attente disque (sans invite/guest)
    return occupe * 1e6 / os.sysconf("SC_CLK_TCK")


def lire_conteneurs():
    """{id: {nom, memoire_mo, usage_us ou None si arrete}} depuis la configuration Proxmox."""
    res = {}
    for conf in glob.glob(os.path.join(PVE_LXC, "*.conf")):
        ident = os.path.basename(conf)[:-5]
        nom, memoire = "CT " + ident, 512
        for ligne in (lire(conf, "") or "").splitlines():
            if ligne.startswith("["):
                break                      # sections d'instantanes : on s'arrete
            if ligne.startswith("hostname:"):
                nom = ligne.split(":", 1)[1].strip()
            elif ligne.startswith("memory:"):
                memoire = int(ligne.split(":", 1)[1].strip() or 512)
        usage = None
        for l in (lire(os.path.join(CGROUP, ident, "cpu.stat"), "") or "").splitlines():
            if l.startswith("usage_usec"):
                usage = int(l.split()[1])
        res[ident] = {"nom": nom, "memoire_mo": memoire, "usage_us": usage}
    return res


# ---------- Imputation d'un intervalle ----------

def imputer(conf, etat, prec, mes, dt, maintenant):
    rend = float(conf.get("rendement_alimentation", 0.85))
    autres = float(conf.get("autres_composants_w", 14))

    # Puissance du processeur : mesuree (RAPL) ou estimee d'apres la charge
    if mes["rapl"] and prec.get("rapl") and set(mes["rapl"]) == set(prec["rapl"]):
        joules = 0.0
        for k, v in mes["rapl"].items():
            d = v["e"] - prec["rapl"][k]["e"]
            if d < 0:
                d += v["max"]              # le compteur a fait le tour
            joules += d / 1e6
        p_proc, source = joules / dt, "mesure RAPL"
    else:
        est = conf.get("estimation_sans_rapl", {"repos_w": 5, "max_w": 65})
        nb = os.cpu_count() or 1
        charge = min(max((mes["cpu_us"] - prec["cpu_us"]) / (dt * 1e6 * nb), 0), 1)
        p_proc, source = est["repos_w"] + (est["max_w"] - est["repos_w"]) * charge, "estimation (pas de RAPL)"

    # Puissance de repos du processeur = plus petite minute des 7 derniers jours
    jour = datetime.date.fromtimestamp(maintenant).isoformat()
    minima = etat.setdefault("minima", {})
    if p_proc >= 0.5:                      # une valeur quasi nulle serait une mesure aberrante
        minima[jour] = round(min(minima.get(jour, p_proc), p_proc), 3)
    for j in sorted(minima)[:-7]:
        del minima[j]
    repos = min(minima.values()) if minima else p_proc

    # Energie a la prise, decoupee en variable et fixe (kWh)
    kwh_var = max(p_proc - repos, 0) * dt / rend / 3.6e6
    kwh_fixe = (repos + autres) * dt / rend / 3.6e6

    # Cle variable : temps processeur de chaque conteneur ; le reste revient a l'hote
    cpu, ram = {}, {}
    for ident, c in mes["conteneurs"].items():
        if c["usage_us"] is None:
            continue                       # conteneur arrete : il ne consomme rien
        ram[c["nom"]] = c["memoire_mo"]
        avant = prec.get("conteneurs", {}).get(ident, {}).get("usage_us")
        cpu[c["nom"]] = max(c["usage_us"] - avant, 0) if avant is not None else 0
    cpu[HOTE] = max((mes["cpu_us"] - prec["cpu_us"]) - sum(cpu.values()), 0)
    ram[HOTE] = int(conf.get("memoire_reservee_hote_mo", 2048))
    somme_cpu, somme_ram = sum(cpu.values()) or 1, sum(ram.values()) or 1

    j = etat.setdefault("jours", {}).setdefault(jour, {"kwh": 0.0, "secondes": 0.0, "services": {}})
    j["kwh"] += kwh_var + kwh_fixe
    j["secondes"] += dt
    instant = {}
    for nom in set(cpu) | set(ram):
        v = kwh_var * cpu.get(nom, 0) / somme_cpu
        f = kwh_fixe * ram.get(nom, 0) / somme_ram
        s = j["services"].setdefault(nom, [0.0, 0.0])
        s[0] += v
        s[1] += f
        instant[nom] = round((v + f) * 3.6e6 / dt, 2)
    return {"p_proc": round(p_proc, 2), "p_mur": round((p_proc + autres) / rend, 1), "repos_proc": round(repos, 2),
            "source": source, "services_w": instant, "horodatage": maintenant}


# ---------- Synthese pour le tableau de bord ----------

def synthese(conf, etat, instant, maintenant):
    prix = float(conf["prix_kwh_eur"])
    jours = etat.get("jours", {})
    auj = datetime.date.fromtimestamp(maintenant)
    cles = sorted(jours)

    def total(js):
        kwh = sum(jours[k]["kwh"] for k in js)
        sec = sum(jours[k]["secondes"] for k in js)
        return kwh, sec

    # Mois en cours et projection a la fin du mois
    mois = [k for k in cles if k.startswith(auj.strftime("%Y-%m"))]
    kwh_mois, sec_mois = total(mois)
    debut = auj.replace(day=1)
    fin = (debut + datetime.timedelta(days=32)).replace(day=1)
    sec_dans_mois = (fin - debut).days * 86400
    proj_mois = kwh_mois / sec_mois * sec_dans_mois * prix if sec_mois > 3600 else None

    # 30 derniers jours glissants
    j30 = [k for k in cles if k > (auj - datetime.timedelta(days=30)).isoformat()]
    kwh30, sec30 = total(j30)
    p_moy = kwh30 * 3.6e6 / sec30 if sec30 > 0 else None          # watts moyens a la prise

    services = {}
    for k in j30:
        for nom, (v, f) in jours[k]["services"].items():
            s = services.setdefault(nom, [0.0, 0.0])
            s[0] += v
            s[1] += f
    tot_srv = sum(v + f for v, f in services.values()) or 1
    liste = sorted(({"nom": n, "kwh": round(v + f, 4), "eur": round((v + f) * prix, 3),
                     "part": round((v + f) / tot_srv * 100, 1), "kwh_variable": round(v, 4),
                     "kwh_fixe": round(f, 4)} for n, (v, f) in services.items()),
                   key=lambda s: -s["kwh"])

    historique = []
    for i in range(29, -1, -1):
        d = (auj - datetime.timedelta(days=i)).isoformat()
        jj = jours.get(d)
        historique.append({"date": d, "kwh": round(jj["kwh"], 4) if jj else None,
                           "heures": round(jj["secondes"] / 3600, 1) if jj else 0,
                           "services": {n: round((v + f) * prix, 4) for n, (v, f) in jj["services"].items()} if jj else {}})

    # Cout total de possession (TCO) mensuel : electricite + amortissement du materiel + domaine
    elec_mois = p_moy * 730 / 1000 * prix if p_moy else None
    materiel = conf.get("materiel", [])
    duree = int(conf.get("amortissement_mois", 36))
    amort = sum(float(m["prix"]) for m in materiel) / duree if duree else 0
    dom = conf.get("domaine_eur_an")
    dom_mois = float(dom) / 12 if dom else 0
    tco = {"electricite": round(elec_mois, 2) if elec_mois is not None else None,
           "amortissement": round(amort, 2), "domaine": round(dom_mois, 2),
           "domaine_renseigne": bool(dom), "materiel": materiel, "duree_amortissement_mois": duree,
           "total": round((elec_mois or 0) + amort + dom_mois, 2)}

    azure = lire_json(AZURE, {"ok": False, "erreur": "prix Azure pas encore recuperes"})
    if azure.get("ok"):
        azure["total_mois"] = round(azure["vm"]["mois"] + azure["disque"]["mois"], 2)

    j_auj = jours.get(auj.isoformat(), {"kwh": 0.0})
    return {
        "maj": maintenant, "prix_kwh": prix, "source_prix": conf.get("source_prix", ""),
        "instant": instant,
        "aujourdhui": {"kwh": round(j_auj["kwh"], 4), "eur": round(j_auj["kwh"] * prix, 3)},
        "mois": {"kwh": round(kwh_mois, 3), "eur": round(kwh_mois * prix, 2),
                 "projection_eur": round(proj_mois, 2) if proj_mois is not None else None,
                 "heures_mesurees": round(sec_mois / 3600, 1)},
        "trente_jours": {"kwh": round(kwh30, 3), "eur": round(kwh30 * prix, 2),
                         "p_moyenne_w": round(p_moy, 1) if p_moy else None,
                         "heures_mesurees": round(sec30 / 3600, 1)},
        "annee_projection_eur": round(p_moy * 8.76 * prix, 0) if p_moy else None,
        "services": liste, "historique": historique, "tco": tco, "azure": azure,
        "hypotheses": {
            "autres_composants_w": conf.get("autres_composants_w"),
            "detail_autres": conf.get("detail_autres", ""),
            "rendement_alimentation": conf.get("rendement_alimentation"),
            "memoire_reservee_hote_mo": conf.get("memoire_reservee_hote_mo"),
        },
    }


def main():
    conf = lire_json(CONF, None)
    if not conf:
        raise SystemExit(f"Configuration absente ou illisible : {CONF}")
    maintenant = MAINTENANT or time.time()
    etat = lire_json(ETAT, {})
    mes = {"t": maintenant, "rapl": lire_rapl(), "cpu_us": lire_cpu_total(), "conteneurs": lire_conteneurs()}
    prec = etat.get("derniere")
    instant = etat.get("instant")
    if prec and 0 < maintenant - prec["t"] <= 600:
        instant = imputer(conf, etat, prec, mes, maintenant - prec["t"], maintenant)
    # sinon (premier passage, redemarrage, longue coupure) : on repart de cette mesure sans rien imputer
    etat["derniere"], etat["instant"] = mes, instant
    jours = etat.get("jours", {})
    for k in sorted(jours)[:-JOURS_GARDES]:
        del jours[k]
    os.makedirs(ETAT_DIR, exist_ok=True)
    ecrire_json(ETAT, etat)
    ecrire_json(SORTIE, synthese(conf, etat, instant, maintenant))


if __name__ == "__main__":
    main()
FIN_RELEVE
cat > /usr/local/sbin/finops-azure.py <<'FIN_AZURE'
#!/usr/bin/env python3
"""Home Cloud - prix Azure equivalents (lance chaque semaine).

Interroge l'API publique des prix de detail Azure (https://prices.azure.com, sans compte ni cle)
pour la machine virtuelle et le disque qui remplaceraient le serveur maison, en euros,
tarif a l'usage (pay-as-you-go), Linux, region configuree.
"""
import datetime
import json
import os
import urllib.parse
import urllib.request

CONF = os.environ.get("FINOPS_CONF", "/etc/homecloud/finops.json")
SORTIE = os.path.join(os.environ.get("ETAT_DIR", "/var/lib/homecloud"), "azure-prix.json")
API = "https://prices.azure.com/api/retail/prices"
HEURES_PAR_MOIS = 730     # convention Azure pour passer d'un prix horaire a un prix mensuel


def requete(filtre):
    url = API + "?" + urllib.parse.urlencode({"currencyCode": "'EUR'", "$filter": filtre},
                                             safe="$'", quote_via=urllib.parse.quote)   # espaces en %20
    articles = []
    while url and len(articles) < 2000:
        with urllib.request.urlopen(url, timeout=30) as r:
            d = json.load(r)
        articles += d.get("Items", [])
        url = d.get("NextPageLink")
    return articles


def prix_vm(region, sku):
    a = requete(f"serviceName eq 'Virtual Machines' and armRegionName eq '{region}' "
                f"and armSkuName eq '{sku}' and priceType eq 'Consumption'")
    linux = [x for x in a if x.get("type") == "Consumption" and x.get("unitOfMeasure") == "1 Hour"
             and "Windows" not in x.get("productName", "")
             and "Spot" not in x.get("skuName", "") and "Low Priority" not in x.get("skuName", "")]
    if not linux:
        raise ValueError(f"aucun prix Linux trouve pour {sku} ({len(a)} lignes recues)")
    m = min(linux, key=lambda x: x["retailPrice"])
    return {"sku": sku, "libelle": m.get("productName", ""), "prix_heure": m["retailPrice"],
            "mois": round(m["retailPrice"] * HEURES_PAR_MOIS, 2), "depuis": m.get("effectiveStartDate", "")[:10]}


def prix_disque(region, sku):
    a = requete(f"serviceName eq 'Storage' and armRegionName eq '{region}' "
                f"and skuName eq '{sku}' and priceType eq 'Consumption'")
    disques = [x for x in a if x.get("unitOfMeasure") == "1/Month" and "Disk" in x.get("meterName", "")
               and "Operations" not in x.get("meterName", "")]
    if not disques:
        raise ValueError(f"aucun prix mensuel trouve pour le disque {sku} ({len(a)} lignes recues)")
    m = min(disques, key=lambda x: x["retailPrice"])
    return {"sku": sku, "libelle": m.get("productName", ""), "mois": round(m["retailPrice"], 2),
            "depuis": m.get("effectiveStartDate", "")[:10]}


def main():
    with open(CONF) as f:
        az = json.load(f)["azure"]
    res = {"date": datetime.date.today().isoformat(), "region": az["region"],
           "region_libelle": az.get("region_libelle", az["region"]), "source": API}
    try:
        res["vm"] = prix_vm(az["region"], az["vm"])
        res["vm"]["libelle_court"] = az.get("vm_libelle", az["vm"])
        res["disque"] = prix_disque(az["region"], az["disque"])
        res["disque"]["libelle_court"] = az.get("disque_libelle", az["disque"])
        res["ok"] = True
    except Exception as e:                      # on garde les anciens prix s'ils existent
        try:
            with open(SORTIE) as f:
                ancien = json.load(f)
            if ancien.get("ok"):
                ancien["avertissement"] = f"mise a jour du {res['date']} ratee : {e}"[:200]
                res = ancien
            else:
                res.update(ok=False, erreur=str(e)[:200])
        except (OSError, ValueError):
            res.update(ok=False, erreur=str(e)[:200])
    tmp = SORTIE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(res, f, ensure_ascii=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, SORTIE)
    print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
FIN_AZURE
chmod 755 /usr/local/sbin/finops-releve.py /usr/local/sbin/finops-azure.py
cat > /opt/supervision/web/finops.html <<'FIN_PAGE'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FinOps du Home Cloud</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --fond:#05080C; --panneau:#0D141C; --bord:#1A2633; --ligne:#131D27; --grille:#17222D;
  --texte:#D6E2EC; --doux:#9FB2C3; --sourd:#7F93A6; --eteint:#16212C;
  --accent:#36C5E6; --orange:#F2A33A; --vert:#43C08A;
  --mono:'JetBrains Mono',ui-monospace,monospace; --sans:'IBM Plex Sans',system-ui,sans-serif;
  /* couleurs des services : palette categorielle validee (fond sombre), ordre fixe */
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#008300; --s7:#9085e9;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--fond);color:var(--texte);font-family:var(--sans)}
main{max-width:1280px;margin:0 auto;padding:24px 16px 48px;display:flex;flex-direction:column;gap:18px}
.mono{font-family:var(--mono)}
header{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:12px;padding-bottom:14px;border-bottom:1px solid #142029}
h1{margin:0;font-family:var(--mono);font-size:20px;letter-spacing:.16em}
h2{margin:0;font-family:var(--mono);font-size:12px;font-weight:400;letter-spacing:.16em;text-transform:uppercase;color:var(--sourd)}
a{color:var(--accent)}
.bascule{display:inline-flex;align-items:center;gap:8px;padding:10px 18px;border-radius:999px;border:1px solid rgba(54,197,230,.45);background:rgba(54,197,230,.10);color:#9EE6F7;font-family:var(--mono);font-size:14px;letter-spacing:.08em;text-decoration:none;cursor:pointer;white-space:nowrap}
.bascule:hover{background:rgba(54,197,230,.22)}
.duo{display:grid;grid-template-columns:minmax(0,1fr);gap:18px}
@media (min-width:1600px){main{max-width:1840px}.duo{grid-template-columns:minmax(0,1.25fr) minmax(0,1fr)}}
.sous{font-size:13px;color:var(--sourd)}
.panneau{background:var(--panneau);border:1px solid var(--bord);border-radius:10px;padding:18px 20px;display:flex;flex-direction:column;gap:14px;min-width:0}
.grille4{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px}
.grille2{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:18px}
.valeur{font-family:var(--mono);font-size:40px;font-weight:700;line-height:1;color:var(--accent)}
.unite{font-family:var(--mono);font-size:16px;color:var(--doux);margin-left:6px}
.legende{display:flex;flex-wrap:wrap;gap:8px 18px;font-size:13px;color:var(--doux)}
.legende span{display:inline-flex;align-items:center;gap:7px}
.pastille{width:10px;height:10px;border-radius:3px;flex:none}
#graphique{position:relative;width:100%}
#graphique svg{display:block;width:100%;height:260px}
#bulle{position:absolute;pointer-events:none;background:#0A1017;border:1px solid var(--bord);border-radius:8px;padding:10px 12px;font-size:13px;min-width:230px;display:none;z-index:2;box-shadow:0 6px 18px rgba(0,0,0,.4)}
#bulle .ligne{display:flex;align-items:center;gap:8px;justify-content:space-between;padding:2px 0}
#bulle .mono{white-space:nowrap}
@media (max-width:640px){.opt{display:none}}
table{width:100%;border-collapse:collapse}
th{font-family:var(--mono);font-size:11px;font-weight:400;color:var(--sourd);text-align:left;padding:0 8px 8px;border-bottom:1px solid var(--bord);white-space:nowrap}
td{padding:10px 8px;border-bottom:1px solid var(--ligne);font-size:14px;color:var(--doux)}
td.nom{color:var(--texte);font-weight:600}
td.n,th.n{text-align:right;font-family:var(--mono);white-space:nowrap}
.defile{overflow-x:auto}
.barre{height:6px;border-radius:3px;background:var(--eteint);min-width:60px}
.barre div{height:6px;border-radius:3px}
.cout{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid var(--ligne);font-size:14px;color:var(--doux)}
.cout b{font-family:var(--mono);color:var(--texte);font-weight:600;white-space:nowrap}
.cout.total{border-bottom:none;font-size:16px;color:var(--texte)}
.cout.total b{font-size:20px;color:var(--accent)}
.verdict{font-size:15px;line-height:1.5;color:var(--texte);padding:12px 14px;border-radius:8px;background:#111B25}
ul.hyp{margin:0;padding-left:18px;color:var(--doux);font-size:14px;line-height:1.6}
details summary{cursor:pointer;color:var(--sourd);font-size:13px}
#attente{color:var(--sourd);font-size:14px}
</style>
</head>
<body>
<main>
<header>
  <div style="display:flex;flex-direction:column;gap:6px">
    <h1>FINOPS · COÛT DU HOME CLOUD</h1>
    <div class="sous" id="periode">Chargement…</div>
  </div>
  <a class="bascule" href="/">‹ &nbsp;SUPERVISION</a>
</header>
<div id="attente">Les premières mesures arrivent : il faut quelques minutes de relevés avant d'afficher des coûts.</div>

<section class="grille4">
  <div class="panneau"><h2>Puissance à la prise</h2>
    <div><span class="valeur" id="k-w">--</span><span class="unite">W</span></div>
    <div class="sous" id="k-w-sous"></div></div>
  <div class="panneau"><h2>Aujourd'hui</h2>
    <div><span class="valeur" id="k-auj">--</span><span class="unite">€</span></div>
    <div class="sous" id="k-auj-sous"></div></div>
  <div class="panneau"><h2>Ce mois-ci</h2>
    <div><span class="valeur" id="k-mois">--</span><span class="unite">€</span></div>
    <div class="sous" id="k-mois-sous"></div></div>
  <div class="panneau"><h2>Sur un an (projection)</h2>
    <div><span class="valeur" id="k-an">--</span><span class="unite">€</span></div>
    <div class="sous" id="k-an-sous"></div></div>
</section>

<div class="duo">
<section class="panneau">
  <div style="display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;align-items:baseline">
    <h2>Coût d'électricité par jour et par service · 30 jours</h2>
    <span class="sous mono" id="prix"></span>
  </div>
  <div class="legende" id="legende"></div>
  <div id="graphique"><svg id="svg" role="img" aria-label="Coût d'électricité par jour, empilé par service"></svg><div id="bulle"></div></div>
  <details><summary>Voir les données jour par jour</summary><div class="defile"><table id="t-jours"></table></div></details>
</section>

<section class="panneau">
  <h2>Imputation des coûts par service · 30 jours (« showback »)</h2>
  <div class="defile"><table>
    <thead><tr><th>SERVICE</th><th class="n opt">EN CE MOMENT</th><th class="n">ÉNERGIE</th><th class="n">COÛT</th><th>PART</th><th class="n opt">DONT VARIABLE</th></tr></thead>
    <tbody id="t-services"></tbody></table></div>
  <div class="sous">Part <b>variable</b> : le processeur au-dessus de son repos, répartie selon le temps processeur réellement consommé.
    Part <b>fixe</b> : repos du processeur, disques et carte mère, répartie selon la mémoire réservée (comme une capacité réservée dans le cloud).</div>
</section>
</div>

<section class="grille2">
  <div class="panneau"><h2>Home Cloud · coût total par mois</h2><div id="tco"></div></div>
  <div class="panneau"><h2>Équivalent Azure · par mois</h2><div id="azure"></div></div>
</section>
<div class="verdict" id="verdict" style="display:none"></div>

<section class="panneau">
  <h2>Méthode et hypothèses</h2>
  <ul class="hyp" id="hypotheses"></ul>
</section>
</main>

<script>
"use strict";
const $ = (id) => document.getElementById(id);
const COULEURS = { "jellyfin": "--s1", "immich": "--s2", "partage": "--s3", "adguard": "--s4", "proxy": "--s5", "Proxmox (hôte)": "--s6" };
const AUTRES = "--s7";
const fr = (n, d = 0) => n == null ? "--" : Number(n).toLocaleString("fr-FR", { minimumFractionDigits: d, maximumFractionDigits: d });
const eur = (n) => n == null ? "--" : fr(n, Math.abs(n) < 1 ? 3 : 2);
const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const couleur = (nom) => css(COULEURS[nom] || AUTRES);
function el(tag, props, enfants) {
  const e = document.createElement(tag);
  if (props) for (const [k, v] of Object.entries(props)) { if (k === "style") e.style.cssText = v; else if (k === "class") e.className = v; else e[k] = v; }
  for (const c of [].concat(enfants ?? [])) e.append(c);
  return e;
}
const svgEl = (tag, attrs) => { const e = document.createElementNS("http://www.w3.org/2000/svg", tag); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; };
const jourCourt = (iso) => { const d = new Date(iso + "T12:00:00"); return d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }); };

let derniere = null;

function graphique(f) {
  const svg = $("svg"), bulle = $("bulle");
  const W = svg.clientWidth || 800, H = 260, g = 58, d = 10, h = 14, b = 26;
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`); svg.replaceChildren();
  const ordre = f.services.map(s => s.nom);
  const jours = f.historique;
  const totaux = jours.map(j => Object.values(j.services).reduce((a, x) => a + x, 0));
  const max = Math.max(0.01, ...totaux);
  const pas = [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2].find(p => max / p <= 4) || 5;
  const haut = Math.ceil(max / pas) * pas;
  const y = (v) => h + (H - h - b) * (1 - v / haut);
  for (let v = 0; v <= haut + 1e-9; v += pas) {
    svg.append(svgEl("line", { x1: g, x2: W - d, y1: y(v), y2: y(v), stroke: css("--grille"), "stroke-width": 1 }));
    const t = svgEl("text", { x: g - 8, y: y(v) + 4, "text-anchor": "end", fill: css("--sourd"), "font-size": 11, "font-family": "JetBrains Mono, monospace" });
    t.textContent = fr(v, pas < 0.1 ? 2 : pas < 1 ? 1 : 0) + " €"; svg.append(t);
  }
  const larg = (W - g - d) / jours.length, barre = Math.max(4, larg - 4);
  jours.forEach((j, i) => {
    const x = g + i * larg + (larg - barre) / 2;
    let base = 0;
    const segs = ordre.filter(n => j.services[n] > 0);
    segs.forEach((nom, k) => {
      const v = j.services[nom], y1 = y(base + v), y0 = y(base);
      const hauteur = Math.max(0, y0 - y1 - (k > 0 ? 2 : 0));            // 2 px d'écart entre segments
      if (hauteur > 0) {
        const r = k === segs.length - 1 ? Math.min(4, hauteur, barre / 2) : 0;   // coins arrondis en haut seulement
        const p = `M${x},${y0 - (k > 0 ? 2 : 0)} V${y1 + r} Q${x},${y1} ${x + r},${y1} H${x + barre - r} Q${x + barre},${y1} ${x + barre},${y1 + r} V${y0 - (k > 0 ? 2 : 0)} Z`;
        svg.append(svgEl("path", { d: p, fill: couleur(nom) }));
      }
      base += v;
    });
    const tous = Math.max(1, Math.ceil(64 / larg));            // une etiquette tous les N jours, sans chevauchement
    if ((jours.length - 1 - i) % tous === 0) {
      const dernier = i === jours.length - 1;
      const t = svgEl("text", { x: dernier ? x + barre : x + barre / 2, y: H - 8, "text-anchor": dernier ? "end" : "middle", fill: css("--sourd"), "font-size": 11, "font-family": "JetBrains Mono, monospace" });
      t.textContent = jourCourt(j.date); svg.append(t);
    }
    const zone = svgEl("rect", { x: g + i * larg, y: h, width: larg, height: H - h - b, fill: "transparent" });
    zone.addEventListener("mouseenter", () => montrer(i));
    zone.addEventListener("touchstart", () => montrer(i), { passive: true });
    zone.addEventListener("mouseleave", () => { bulle.style.display = "none"; });
    svg.append(zone);
  });
  function montrer(i) {
    const j = jours[i];
    const lignes = ordre.filter(n => j.services[n] > 0).map(n => el("div", { class: "ligne" }, [
      el("span", { style: "display:inline-flex;align-items:center;gap:7px;color:var(--doux)" }, [el("span", { class: "pastille", style: "background:" + couleur(n) }), n]),
      el("span", { class: "mono", style: "color:var(--texte)" }, eur(j.services[n]) + " €")]));
    bulle.replaceChildren(
      el("div", { style: "font-weight:600;margin-bottom:6px" }, new Date(j.date + "T12:00:00").toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" })),
      ...(lignes.length ? lignes : [el("div", { style: "color:var(--sourd)" }, "Pas de mesure ce jour-là")]),
      el("div", { class: "ligne", style: "border-top:1px solid var(--bord);margin-top:6px;padding-top:6px" }, [
        el("span", { style: "color:var(--sourd)" }, j.kwh != null ? fr(j.kwh, 2) + " kWh · mesuré " + fr(j.heures, 0) + " h / 24" : ""),
        el("span", { class: "mono", style: "font-weight:600" }, eur(totaux[i]) + " €")]));
    bulle.style.display = "block";
    const x = g + i * larg + larg / 2, bw = bulle.offsetWidth;
    bulle.style.left = Math.min(Math.max(0, x - bw / 2), W - bw) + "px";
    bulle.style.top = "0px";
  }
  $("legende").replaceChildren(...ordre.map(n => el("span", null, [el("span", { class: "pastille", style: "background:" + couleur(n) }), n])));
  $("t-jours").replaceChildren(
    el("thead", null, el("tr", null, [el("th", null, "JOUR"), el("th", { class: "n" }, "kWh"), el("th", { class: "n" }, "COÛT"), el("th", { class: "n" }, "HEURES MESURÉES")])),
    el("tbody", null, jours.slice().reverse().filter(j => j.kwh != null).map((j, k) => el("tr", null, [
      el("td", null, jourCourt(j.date)), el("td", { class: "n" }, fr(j.kwh, 3)),
      el("td", { class: "n" }, eur(Object.values(j.services).reduce((a, x) => a + x, 0)) + " €"), el("td", { class: "n" }, fr(j.heures, 1))]))));
}

function afficher(f) {
  derniere = f;
  const pret = f.trente_jours && f.trente_jours.heures_mesurees > 0;
  $("attente").style.display = pret ? "none" : "block";
  const ins = f.instant || {};
  $("periode").textContent = "Mis à jour " + new Date(f.maj * 1000).toLocaleString("fr-FR", { weekday: "long", hour: "2-digit", minute: "2-digit" })
    + " · " + fr(f.trente_jours.heures_mesurees, 0) + " h de mesures sur 30 jours";
  $("k-w").textContent = fr(ins.p_mur, 0);
  $("k-w-sous").textContent = ins.p_proc != null ? `dont processeur ${fr(ins.p_proc, 1)} W (${ins.source}) · repos ${fr(ins.repos_proc, 1)} W` : "";
  $("k-auj").textContent = eur(f.aujourdhui.eur);
  $("k-auj-sous").textContent = fr(f.aujourdhui.kwh, 3) + " kWh depuis minuit";
  $("k-mois").textContent = eur(f.mois.eur);
  $("k-mois-sous").textContent = f.mois.projection_eur != null ? `projection fin de mois : ${eur(f.mois.projection_eur)} €` : "projection disponible après 1 h de mesures";
  $("k-an").textContent = fr(f.annee_projection_eur, 0);
  $("k-an-sous").textContent = f.trente_jours.p_moyenne_w != null ? `au rythme moyen de ${fr(f.trente_jours.p_moyenne_w, 1)} W` : "";
  $("prix").textContent = fr(f.prix_kwh, 4) + " €/kWh";

  if (pret) graphique(f);

  const totalKwh = f.services.reduce((a, s) => a + s.kwh, 0) || 1;
  $("t-services").replaceChildren(...f.services.map(s => el("tr", null, [
    el("td", { class: "nom" }, el("span", { style: "display:inline-flex;align-items:center;gap:9px" }, [el("span", { class: "pastille", style: "background:" + couleur(s.nom) }), s.nom])),
    el("td", { class: "n opt" }, (ins.services_w && ins.services_w[s.nom] != null ? fr(ins.services_w[s.nom], 1) : "--") + " W"),
    el("td", { class: "n" }, fr(s.kwh, 3) + " kWh"),
    el("td", { class: "n", style: "color:var(--texte)" }, eur(s.eur) + " €"),
    el("td", null, el("div", { style: "display:flex;align-items:center;gap:10px" }, [
      el("div", { class: "barre", style: "flex:1" }, el("div", { style: `width:${s.kwh / totalKwh * 100}%;background:${couleur(s.nom)}` })),
      el("span", { class: "mono", style: "font-size:13px;width:44px;text-align:right" }, fr(s.part, 0) + " %")])),
    el("td", { class: "n opt" }, fr(s.kwh ? s.kwh_variable / s.kwh * 100 : 0, 0) + " %")])));

  // Coût total de possession
  const t = f.tco, az = f.azure || {};
  const ligne = (lib, val, cls) => el("div", { class: "cout" + (cls ? " " + cls : "") }, [el("span", null, lib), el("b", null, val)]);
  $("tco").replaceChildren(
    ligne("Électricité (au rythme moyen mesuré)", t.electricite != null ? eur(t.electricite) + " €" : "--"),
    ligne(`Matériel acheté (${fr(t.materiel.reduce((a, m) => a + m.prix, 0), 2)} € amortis sur ${t.duree_amortissement_mois} mois)`, eur(t.amortissement) + " €"),
    ligne("Nom de domaine", t.domaine_renseigne ? eur(t.domaine) + " €" : "à renseigner"),
    ligne("Total", eur(t.total) + " €", "total"));
  if (az.ok) {
    $("azure").replaceChildren(
      ligne(`Machine virtuelle ${az.vm.libelle_court}, Linux, ${az.region_libelle}`, eur(az.vm.mois) + " €"),
      ligne(az.disque.libelle_court, eur(az.disque.mois) + " €"),
      ligne("Total", eur(az.total_mois) + " €", "total"),
      el("div", { class: "sous" }, `Prix publics à l'usage relevés le ${new Date(az.date).toLocaleDateString("fr-FR")} sur prices.azure.com${az.avertissement ? " · " + az.avertissement : ""}.`));
    const v = $("verdict");
    v.style.display = "block";
    const r = az.total_mois / Math.max(t.total, 0.01);
    v.textContent = `À capacité comparable, le même service coûterait environ ${eur(az.total_mois)} € par mois sur Azure, contre ${eur(t.total)} € chez toi`
      + (r >= 1.5 ? `, soit ${fr(r, 0)} fois plus. ` : r >= 1 ? `, un peu plus cher. ` : `, moins cher que chez toi. `)
      + `Mais le cloud apporte ce que le serveur maison n'a pas : haute disponibilité, centre de données, sauvegarde hors site, aucune panne matérielle à gérer.`;
  } else {
    $("azure").replaceChildren(el("div", { class: "sous" }, "Prix Azure indisponibles pour l'instant" + (az.erreur ? " : " + az.erreur : ".")));
  }

  const h = f.hypotheses || {};
  $("hypotheses").replaceChildren(...[
    `Prix de l'électricité : ${fr(f.prix_kwh, 4)} €/kWh — ${f.source_prix}. L'abonnement n'est pas compté : il serait payé même sans serveur (coût non imputable).`,
    `Processeur : énergie mesurée chaque minute par ses compteurs intégrés (RAPL). Le reste du PC est estimé à ${fr(h.autres_composants_w, 0)} W : ${h.detail_autres}`,
    `Rendement de l'alimentation supposé : ${fr((h.rendement_alimentation || 0) * 100, 0)} %. Une prise wattmètre permettrait de confirmer la puissance réelle.`,
    `Répartition : part variable selon le temps processeur ; part fixe selon la mémoire réservée (l'hôte Proxmox compte pour ${fr(h.memoire_reservee_hote_mo, 0)} Mo). Le transcodage matériel de Jellyfin passe par la puce graphique : il est un peu sous-estimé par la clé « temps processeur ».`,
    `Coût total de possession : seuls les achats faits pour le projet sont amortis ; les pièces que tu avais déjà sont des coûts irrécupérables, hors calcul.`,
    `Équivalent Azure : tarif à l'usage, sans réservation ni remise ; la sortie de données (streaming) et les sauvegardes ne sont pas comptées, ce qui avantage Azure.`,
  ].map(x => el("li", null, x)));
}

async function rafraichir() {
  try {
    const r = await fetch("/api/etat", { cache: "no-store" });
    const e = await r.json();
    if (e.finops) afficher(e.finops);
  } catch (err) { $("periode").textContent = "Données indisponibles : le collecteur ne répond pas"; }
}
rafraichir(); setInterval(rafraichir, 30000);
addEventListener("resize", () => { if (derniere) graphique(derniere); });
</script>
</body>
</html>
FIN_PAGE
chmod 644 /opt/supervision/web/finops.html
echo "OK"

echo
echo "=== 3. Minuteurs ==="
cat > /etc/systemd/system/finops-releve.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - releve FinOps (energie et imputation par service)

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/finops-releve.py
Nice=10
FIN_UNITE
cat > /etc/systemd/system/finops-releve.timer <<'FIN_UNITE'
[Unit]
Description=Releve FinOps chaque minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
FIN_UNITE
cat > /etc/systemd/system/finops-azure.service <<'FIN_UNITE'
[Unit]
Description=Home Cloud - prix Azure equivalents (API publique prices.azure.com)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/finops-azure.py
FIN_UNITE
cat > /etc/systemd/system/finops-azure.timer <<'FIN_UNITE'
[Unit]
Description=Prix Azure chaque semaine

[Timer]
OnCalendar=Mon 06:00
Persistent=true

[Install]
WantedBy=timers.target
FIN_UNITE
systemctl daemon-reload
systemctl enable --now finops-releve.timer finops-azure.timer

echo
echo "=== 4. Prix Azure (premier releve) ==="
systemctl start finops-azure.service || true
python3 - <<'FIN_TEST'
import json
a = json.load(open("/var/lib/homecloud/azure-prix.json"))
if a.get("ok"):
    print(f"VM {a['vm']['sku']} : {a['vm']['prix_heure']} EUR/h -> {a['vm']['mois']} EUR/mois")
    print(f"Disque {a['disque']['sku']} : {a['disque']['mois']} EUR/mois")
else:
    print("Prix Azure indisponibles :", a.get("erreur"))
FIN_TEST

echo
echo "=== 5. Branchement du collecteur et de l'ecran ==="
cp -a /opt/supervision/collecteur.py /opt/supervision/collecteur.py.avant-finops
cp -a /opt/supervision/web/index.html /opt/supervision/web/index.html.avant-finops
python3 - <<'FIN_CORRECTIF'
import os, sys
COLL = os.environ.get("COLL", "/opt/supervision/collecteur.py")
PAGE = os.environ.get("PAGE_WEB", "/opt/supervision/web/index.html")


def remplacer(texte, avant, apres, nom):
    if texte.count(avant) != 1:
        sys.exit(f"ERREUR : repere introuvable dans {nom}, rien n'a ete modifie.")
    return texte.replace(avant, apres)


c = open(COLL).read()
p = open(PAGE).read()
if "lire_finops" in c:
    print("Collecteur deja branche sur le FinOps, rien a faire.")
    sys.exit(0)

# 1. Lecture de la synthese FinOps (toutes les 15 s, avec les autres mesures lentes)
c = remplacer(c, "def boucle_lente():", '''def lire_finops():
    try:
        with open(os.path.join(ETAT_DIR, "finops.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def boucle_lente():''', "le collecteur")
c = remplacer(c, "sauvegardes=lire_sauvegardes())", "sauvegardes=lire_sauvegardes(), finops=lire_finops())", "le collecteur")

# 2. Nouvelle page /finops servie a cote de l'ecran principal
c = remplacer(c, '''        elif self.path in ("/", "/index.html"):''', '''        elif self.path in ("/finops", "/finops.html"):
            try:
                with open(os.path.join(os.path.dirname(PAGE), "finops.html"), "rb") as f:
                    corps = f.read()
            except OSError:
                corps = "Page FinOps absente".encode()
            typ = "text/html; charset=utf-8"
        elif self.path in ("/", "/index.html"):''', "le collecteur")

# 3. Ecran principal : puissance et cout du mois dans la ligne d'en-tete
p = remplacer(p, '''" · en service depuis " + depuis(e.uptime || 0);''',
              '''" · en service depuis " + depuis(e.uptime || 0)
    + (e.finops && e.finops.instant ? " · " + fr(e.finops.instant.p_mur) + " W · " + fr(e.finops.mois.eur, 2) + " € ce mois-ci" : "");''',
              "la page")

open(COLL, "w").write(c)
open(PAGE, "w").write(p)
print("Collecteur et ecran principal branches sur le FinOps.")
FIN_CORRECTIF
python3 -m py_compile /opt/supervision/collecteur.py && echo "Collecteur : syntaxe OK"
systemctl restart supervision.service
systemctl restart ecran-supervision.service

echo
echo "=== 6. Premieres mesures (2 minutes) ==="
sleep 125
python3 - <<'FIN_TEST'
import json
f = json.load(open("/var/lib/homecloud/finops.json"))
i = f.get("instant") or {}
print(f"Processeur : {i.get('p_proc')} W ({i.get('source')}) | a la prise (estime) : {i.get('p_mur')} W")
for nom, w in sorted((i.get("services_w") or {}).items(), key=lambda x: -x[1]):
    print(f"  {nom:<16} {w:>6} W")
FIN_TEST
echo
echo "TERMINE. Page : https://tableau.maison.exemple.fr/finops"
