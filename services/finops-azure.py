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
