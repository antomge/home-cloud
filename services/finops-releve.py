#!/usr/bin/env python3
"""Home Cloud - FinOps reading (run every minute by a systemd timer, as root).

1. Measures CPU energy with its RAPL counters (Intel), in joules.
2. Estimates power at the wall: (CPU + other components) / power supply efficiency.
3. Allocates each minute's energy to the services (showback):
   - VARIABLE share (CPU above idle) -> pro rata of the CPU time consumed;
   - FIXED share (idle + disks + motherboard) -> pro rata of the reserved memory,
     like reserved capacity in the cloud.
4. Accumulates per day, then writes a summary readable by the dashboard.
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
MAINTENANT = float(os.environ.get("FINOPS_MAINTENANT", "0")) or None   # for tests only

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


# ---------- Measurements ----------

def lire_rapl():
    """CPU energy counters (packages), in microjoules."""
    paquets = {}
    for d in glob.glob(os.path.join(RAPL, "intel-rapl:*")):
        if not re.search(r"intel-rapl:\d+$", d):
            continue                      # skip the sub-domains (cores, graphics...)
        e, m = lire(os.path.join(d, "energy_uj")), lire(os.path.join(d, "max_energy_range_uj"))
        if e and e.isdigit() and m and m.isdigit():
            paquets[os.path.basename(d)] = {"e": int(e), "max": int(m)}
    return paquets


def lire_cpu_total():
    """Busy CPU time of the whole machine, in microseconds."""
    with open(PROC_STAT) as f:
        v = [int(x) for x in f.readline().split()[1:]]
    occupe = sum(v[:8]) - v[3] - v[4]     # everything except idle and iowait (guest excluded)
    return occupe * 1e6 / os.sysconf("SC_CLK_TCK")


def lire_conteneurs():
    """{id: {nom, memoire_mo, usage_us or None if stopped}} from the Proxmox configuration."""
    res = {}
    for conf in glob.glob(os.path.join(PVE_LXC, "*.conf")):
        ident = os.path.basename(conf)[:-5]
        nom, memoire = "CT " + ident, 512
        for ligne in (lire(conf, "") or "").splitlines():
            if ligne.startswith("["):
                break                      # snapshot sections: stop here
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


# ---------- Allocation of one interval ----------

def imputer(conf, etat, prec, mes, dt, maintenant):
    rend = float(conf.get("rendement_alimentation", 0.85))
    autres = float(conf.get("autres_composants_w", 14))

    # CPU power: measured (RAPL) or estimated from the load
    if mes["rapl"] and prec.get("rapl") and set(mes["rapl"]) == set(prec["rapl"]):
        joules = 0.0
        for k, v in mes["rapl"].items():
            d = v["e"] - prec["rapl"][k]["e"]
            if d < 0:
                d += v["max"]              # the counter wrapped around
            joules += d / 1e6
        p_proc, source = joules / dt, "mesure RAPL"
    else:
        est = conf.get("estimation_sans_rapl", {"repos_w": 5, "max_w": 65})
        nb = os.cpu_count() or 1
        charge = min(max((mes["cpu_us"] - prec["cpu_us"]) / (dt * 1e6 * nb), 0), 1)
        p_proc, source = est["repos_w"] + (est["max_w"] - est["repos_w"]) * charge, "estimation (pas de RAPL)"

    # CPU idle power = lowest minute of the last 7 days
    jour = datetime.date.fromtimestamp(maintenant).isoformat()
    minima = etat.setdefault("minima", {})
    if p_proc >= 0.5:                      # a near-zero value would be a bogus reading
        minima[jour] = round(min(minima.get(jour, p_proc), p_proc), 3)
    for j in sorted(minima)[:-7]:
        del minima[j]
    repos = min(minima.values()) if minima else p_proc

    # Energy at the wall, split into variable and fixed (kWh)
    kwh_var = max(p_proc - repos, 0) * dt / rend / 3.6e6
    kwh_fixe = (repos + autres) * dt / rend / 3.6e6

    # Variable key: CPU time of each container; the rest goes to the host
    cpu, ram = {}, {}
    for ident, c in mes["conteneurs"].items():
        if c["usage_us"] is None:
            continue                       # stopped container: it consumes nothing
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


# ---------- Summary for the dashboard ----------

def synthese(conf, etat, instant, maintenant):
    prix = float(conf["prix_kwh_eur"])
    jours = etat.get("jours", {})
    auj = datetime.date.fromtimestamp(maintenant)
    cles = sorted(jours)

    def total(js):
        kwh = sum(jours[k]["kwh"] for k in js)
        sec = sum(jours[k]["secondes"] for k in js)
        return kwh, sec

    # Current month and projection to the end of the month
    mois = [k for k in cles if k.startswith(auj.strftime("%Y-%m"))]
    kwh_mois, sec_mois = total(mois)
    debut = auj.replace(day=1)
    fin = (debut + datetime.timedelta(days=32)).replace(day=1)
    sec_dans_mois = (fin - debut).days * 86400
    proj_mois = kwh_mois / sec_mois * sec_dans_mois * prix if sec_mois > 3600 else None

    # Rolling last 30 days
    j30 = [k for k in cles if k > (auj - datetime.timedelta(days=30)).isoformat()]
    kwh30, sec30 = total(j30)
    p_moy = kwh30 * 3.6e6 / sec30 if sec30 > 0 else None          # average watts at the wall

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

    # Monthly total cost of ownership (TCO): electricity + hardware depreciation + domain
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
        raise SystemExit(f"Configuration missing or unreadable: {CONF}")
    maintenant = MAINTENANT or time.time()
    etat = lire_json(ETAT, {})
    mes = {"t": maintenant, "rapl": lire_rapl(), "cpu_us": lire_cpu_total(), "conteneurs": lire_conteneurs()}
    prec = etat.get("derniere")
    instant = etat.get("instant")
    if prec and 0 < maintenant - prec["t"] <= 600:
        instant = imputer(conf, etat, prec, mes, maintenant - prec["t"], maintenant)
    # otherwise (first run, reboot, long outage): restart from this reading without allocating anything
    etat["derniere"], etat["instant"] = mes, instant
    jours = etat.get("jours", {})
    for k in sorted(jours)[:-JOURS_GARDES]:
        del jours[k]
    os.makedirs(ETAT_DIR, exist_ok=True)
    ecrire_json(ETAT, etat)
    ecrire_json(SORTIE, synthese(conf, etat, instant, maintenant))


if __name__ == "__main__":
    main()
