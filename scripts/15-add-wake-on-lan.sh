#!/bin/bash
# Home Cloud - turn the gaming PC on remotely (Wake-on-LAN) from the /liens page
#  - GET  /api/pc         : is the PC online? (read from "tailscale status")
#  - POST /api/pc/reveil  : sends the magic packet on the LAN (header X-Reveil: 1 required,
#                           at most one wake-up every 10 seconds)
#  - "Mon PC" section with an "Allumer" ("turn on") button at the top of /liens
# Prerequisites on the PC: Wake on LAN enabled in the BIOS (and S5 power saving off),
# "Wake on Magic Packet" on the Ethernet adapter, Windows Fast Startup disabled.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: must be run as root."; exit 1; fi
COLL=/opt/supervision/collecteur.py
PAGE=/opt/supervision/web/liens.html
ENVF=/etc/supervision.env
for f in "$COLL" "$PAGE" "$ENVF"; do
  if [ ! -f "$f" ]; then echo "ERROR: $f not found."; exit 1; fi
done
if grep -q "def reveiller_pc" "$COLL"; then echo "Already installed, nothing to do."; exit 0; fi
if ! command -v tailscale >/dev/null; then echo "ERROR: tailscale not installed."; exit 1; fi

read -rp "PC MAC address (e.g. AA:BB:CC:DD:EE:FF): " PC_MAC
if ! [[ "$PC_MAC" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "ERROR: invalid MAC address."; exit 1
fi
read -rp "PC name in Tailscale (e.g. my-pc): " PC_TAILSCALE
read -rp "LAN broadcast address [192.168.1.255]: " PC_DIFFUSION
PC_DIFFUSION=${PC_DIFFUSION:-192.168.1.255}

echo "=== 1. Backups ==="
cp -a "$COLL" "$COLL.avant-reveil"
cp -a "$PAGE" "$PAGE.avant-reveil"
cp -a "$ENVF" "$ENVF.avant-reveil"
echo "OK (*.avant-reveil)"

echo
echo "=== 2. PC settings in $ENVF ==="
grep -q "^PC_MAC=" "$ENVF" || echo "PC_MAC=$PC_MAC" >> "$ENVF"
grep -q "^PC_TAILSCALE=" "$ENVF" || echo "PC_TAILSCALE=$PC_TAILSCALE" >> "$ENVF"
grep -q "^PC_DIFFUSION=" "$ENVF" || echo "PC_DIFFUSION=$PC_DIFFUSION" >> "$ENVF"
chown root:supervision "$ENVF"
chmod 640 "$ENVF"

echo
echo "=== 3. Patching the collector and the links page ==="
cat > /tmp/correctif-reveil.py <<'FIN_PY'
import os, sys
COLL = os.environ.get("COLL", "/opt/supervision/collecteur.py")
LIENS = os.environ.get("PAGE_LIENS", "/opt/supervision/web/liens.html")


def remplacer(texte, avant, apres, nom):
    if texte.count(avant) != 1:
        sys.exit(f"ERROR: anchor not found ({nom}), nothing was modified.")
    return texte.replace(avant, apres)


c = open(COLL).read()
p = open(LIENS).read()
if "def reveiller_pc" in c:
    print("PC wake-up already installed, nothing to do.")
    sys.exit(0)

# ---------- Collector ----------
c = remplacer(c, "import ssl\n", "import socket\nimport ssl\n", "collecteur")
c = remplacer(c, "class Gestionnaire(BaseHTTPRequestHandler):",
              '''PC_MAC = os.environ.get("PC_MAC", "")
PC_TAILSCALE = os.environ.get("PC_TAILSCALE", "")
PC_DIFFUSION = os.environ.get("PC_DIFFUSION", "192.168.1.255")
dernier_reveil = [0.0]


def etat_pc():
    """Is the PC on? Check whether it is online in Tailscale."""
    if not (PC_MAC and PC_TAILSCALE):
        return {"configure": False}
    try:
        r = subprocess.run(["tailscale", "status", "--json"],
                           capture_output=True, text=True, timeout=5)
        pairs = json.loads(r.stdout).get("Peer") or {}
        for p in pairs.values():
            nom = (p.get("DNSName") or "").split(".")[0].lower()
            if nom == PC_TAILSCALE.lower():
                return {"configure": True, "en_ligne": bool(p.get("Online"))}
        return {"configure": True, "en_ligne": False,
                "erreur": "machine introuvable dans Tailscale"}
    except Exception as e:
        return {"configure": True, "en_ligne": False, "erreur": str(e)[:150]}


def reveiller_pc():
    """Send the Wake-on-LAN magic packet: 6 x FF, then the MAC address 16 times."""
    if not PC_MAC:
        return {"ok": False, "erreur": "PC_MAC non configure"}
    if time.time() - dernier_reveil[0] < 10:
        return {"ok": False, "erreur": "signal deja envoye, patiente quelques secondes"}
    try:
        octets = bytes.fromhex(PC_MAC.replace(":", "").replace("-", ""))
        if len(octets) != 6:
            raise ValueError("adresse MAC invalide")
        paquet = b"\\xff" * 6 + octets * 16
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for _ in range(3):
                for port in (9, 7):
                    s.sendto(paquet, (PC_DIFFUSION, port))
        dernier_reveil[0] = time.time()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "erreur": str(e)[:150]}


class Gestionnaire(BaseHTTPRequestHandler):''', "collecteur")
c = remplacer(c, '''        elif self.path in ("/finops", "/finops.html"):''',
              '''        elif self.path.startswith("/api/pc"):
            corps = json.dumps(etat_pc()).encode()
            typ = "application/json"
        elif self.path in ("/finops", "/finops.html"):''', "collecteur")
c = remplacer(c, "    def log_message(self, *args):", '''    def do_POST(self):
        # Required header: another website cannot trigger the wake-up (CSRF)
        if self.path != "/api/pc/reveil" or self.headers.get("X-Reveil") != "1":
            self.send_error(403)
            return
        corps = json.dumps(reveiller_pc()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):''', "collecteur")

# ---------- Links page ----------
p = remplacer(p, "button:hover{border-color:var(--accent);color:var(--accent)}",
              "button:hover{border-color:var(--accent);color:var(--accent)}\n"
              "button:disabled{opacity:.5;cursor:default}", "page des liens")
p = remplacer(p, "<h2>Services</h2>", '''<h2>Mon PC</h2>
<div class="lien"><div><div class="nom">PC de jeu</div>
  <div class="det" id="pc-etat">verification...</div></div>
  <button id="pc-bouton">Allumer</button></div>

<h2>Services</h2>''', "page des liens")
p = remplacer(p, "</body>", '''<script>
const pcEtat = document.getElementById("pc-etat");
const pcBouton = document.getElementById("pc-bouton");
let pcAttente = false;
function pcBoutonEtat(actif, texte) { pcBouton.disabled = !actif; pcBouton.textContent = texte; }
async function etatPc() {
  try {
    const e = await (await fetch("/api/pc", { cache: "no-store" })).json();
    if (!e.configure) { pcEtat.textContent = "non configuré"; pcBoutonEtat(false, "Allumer"); return; }
    if (e.en_ligne) {
      pcAttente = false; pcEtat.textContent = "● allumé"; pcEtat.style.color = "#43C08A";
      pcBoutonEtat(false, "Allumé"); return;
    }
    pcEtat.style.color = "";
    if (!pcAttente) {
      pcEtat.textContent = "○ éteint" + (e.erreur ? " (" + e.erreur + ")" : "");
      pcBoutonEtat(true, "Allumer");
    }
  } catch (err) { pcEtat.textContent = "état indisponible"; }
}
pcBouton.addEventListener("click", async () => {
  pcBoutonEtat(false, "Envoi…");
  try {
    const r = await fetch("/api/pc/reveil", { method: "POST", headers: { "X-Reveil": "1" } });
    const e = await r.json();
    if (e.ok) {
      pcAttente = true; pcEtat.textContent = "démarrage en cours (1 à 2 min)…";
      pcBoutonEtat(false, "Signal envoyé");
    } else {
      pcEtat.textContent = "échec : " + (e.erreur || "?"); pcBoutonEtat(true, "Allumer");
    }
  } catch (err) { pcEtat.textContent = "échec de l'envoi"; pcBoutonEtat(true, "Allumer"); }
  setTimeout(() => { pcAttente = false; etatPc(); }, 180000);
});
etatPc(); setInterval(etatPc, 10000);
</script>
</body>''', "page des liens")

open(COLL, "w").write(c)
open(LIENS, "w").write(p)
print("Collector and links page updated.")
FIN_PY
COLL="$COLL" PAGE_LIENS="$PAGE" python3 /tmp/correctif-reveil.py
rm -f /tmp/correctif-reveil.py
if ! python3 -m py_compile "$COLL"; then
  echo "SYNTAX ERROR: restoring the previous version."
  cp -a "$COLL.avant-reveil" "$COLL"
  cp -a "$PAGE.avant-reveil" "$PAGE"
  exit 1
fi

echo
echo "=== 4. Restarting the service ==="
systemctl restart supervision.service
sleep 3
systemctl is-active supervision.service
echo "PC status as seen by the server:"
curl -s http://127.0.0.1:8088/api/pc; echo
echo
echo "Done. Button: https://tableau.maison.<domain>/liens"
