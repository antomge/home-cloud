#!/bin/bash
# Home Cloud - /liens page that gathers all the useful links
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
cat > /opt/supervision/web/liens.html <<'FIN_PAGE'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Liens du Home Cloud</title>
<style>
:root{--fond:#05080C;--panneau:#0D141C;--bord:#1A2633;--texte:#D6E2EC;
  --doux:#9FB2C3;--sourd:#7F93A6;--accent:#36C5E6;
  --mono:ui-monospace,'JetBrains Mono',monospace;--sans:system-ui,sans-serif}
*{box-sizing:border-box}
body{margin:0;background:var(--fond);color:var(--texte);font-family:var(--sans)}
main{max-width:760px;margin:0 auto;padding:28px 16px 48px}
h1{font-family:var(--mono);font-size:18px;letter-spacing:.16em;margin:0 0 24px}
h2{font-family:var(--mono);font-size:12px;font-weight:400;letter-spacing:.16em;
  text-transform:uppercase;color:var(--sourd);margin:26px 0 10px}
a.lien,div.lien{display:flex;align-items:center;justify-content:space-between;gap:12px;
  padding:14px 16px;margin-bottom:8px;background:var(--panneau);border:1px solid var(--bord);
  border-radius:10px;color:var(--texte);text-decoration:none}
a.lien:hover{border-color:var(--accent)}
.nom{font-weight:600;font-size:16px}
.det{font-size:13px;color:var(--sourd);margin-top:3px;font-family:var(--mono);word-break:break-all}
.fleche{color:var(--accent);font-size:20px}
button{background:none;border:1px solid var(--bord);color:var(--doux);border-radius:8px;
  padding:8px 12px;font-size:13px;cursor:pointer;white-space:nowrap}
button:hover{border-color:var(--accent);color:var(--accent)}
</style>
</head>
<body>
<main>
<h1>LIENS · HOME CLOUD</h1>

<h2>Services</h2>
<a class="lien" href="https://jellyfin.maison.example.com"><div><div class="nom">Jellyfin</div>
  <div class="det">films et séries</div></div><span class="fleche">›</span></a>
<a class="lien" href="https://immich.maison.example.com"><div><div class="nom">Immich</div>
  <div class="det">photos et recherche</div></div><span class="fleche">›</span></a>
<a class="lien" href="/"><div><div class="nom">Écran de supervision</div>
  <div class="det">état du serveur</div></div><span class="fleche">›</span></a>
<a class="lien" href="/finops"><div><div class="nom">Coûts FinOps</div>
  <div class="det">consommation et coût par service</div></div><span class="fleche">›</span></a>

<h2>Administration</h2>
<a class="lien" href="https://proxmox.maison.example.com"><div><div class="nom">Proxmox</div>
  <div class="det">hyperviseur · compte root, realm Linux PAM</div></div><span class="fleche">›</span></a>
<a class="lien" href="https://adguard.maison.example.com"><div><div class="nom">AdGuard</div>
  <div class="det">DNS et bloqueur de publicités</div></div><span class="fleche">›</span></a>
<a class="lien" href="https://login.tailscale.com/admin/machines"><div><div class="nom">Console Tailscale</div>
  <div class="det">appareils, DNS, partages</div></div><span class="fleche">›</span></a>
<a class="lien" href="https://dash.cloudflare.com"><div><div class="nom">Cloudflare</div>
  <div class="det">domaine example.com</div></div><span class="fleche">›</span></a>
<a class="lien" href="http://192.168.1.1"><div><div class="nom">Livebox</div>
  <div class="det">à la maison seulement</div></div><span class="fleche">›</span></a>
<a class="lien" href="https://github.com/antomge/home-cloud"><div><div class="nom">Dépôt GitHub</div>
  <div class="det">documentation du projet</div></div><span class="fleche">›</span></a>

<h2>Dossiers partagés (à copier dans l'Explorateur ou l'app Fichiers)</h2>
<div class="lien"><div><div class="nom">Photos</div><div class="det">\\anto-partage-pf\photos</div></div>
  <button data-copie="\\anto-partage-pf\photos">Copier</button></div>
<div class="lien"><div><div class="nom">Films</div><div class="det">\\anto-partage-pf\films</div></div>
  <button data-copie="\\anto-partage-pf\films">Copier</button></div>
<div class="lien"><div><div class="nom">iPhone (app Fichiers)</div><div class="det">smb://anto-partage-pf</div></div>
  <button data-copie="smb://anto-partage-pf">Copier</button></div>
</main>
<script>
document.querySelectorAll("button[data-copie]").forEach(b => b.addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(b.dataset.copie); b.textContent = "Copié ✓"; }
  catch (e) { b.textContent = "Échec"; }
  setTimeout(() => { b.textContent = "Copier"; }, 1500);
}));
</script>
</body>
</html>
FIN_PAGE
chmod 644 /opt/supervision/web/liens.html
cp -a /opt/supervision/collecteur.py /opt/supervision/collecteur.py.avant-liens
python3 - <<'FIN_CORRECTIF'
import os, sys
COLL = os.environ.get("COLL", "/opt/supervision/collecteur.py")
c = open(COLL).read()
if '"/liens"' in c:
    print("Route /liens already present.")
    sys.exit(0)
avant = '''        elif self.path in ("/finops", "/finops.html"):'''
apres = '''        elif self.path in ("/liens", "/links"):
            try:
                with open(os.path.join(os.path.dirname(PAGE), "liens.html"), "rb") as f:
                    corps = f.read()
            except OSError:
                corps = "Page des liens absente".encode()
            typ = "text/html; charset=utf-8"
''' + avant
if c.count(avant) != 1:
    sys.exit("ERROR: anchor not found in the collector, nothing was modified.")
open(COLL, "w").write(c.replace(avant, apres))
print("Route /liens added to the collector.")
FIN_CORRECTIF
python3 -m py_compile /opt/supervision/collecteur.py && echo "Collector: syntax OK"
systemctl restart supervision.service
sleep 2
curl -s -o /dev/null -w "Page /liens: %{http_code}\n" http://127.0.0.1:8088/liens
echo "DONE: https://tableau.maison.example.com/liens"
