#!/bin/bash
# Home Cloud - bouton pour basculer entre l'ecran de supervision et la page des couts
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "ERREUR : a lancer en root."; exit 1; fi
cp -a /opt/supervision/web/index.html /opt/supervision/web/index.html.avant-bascule
cp -a /opt/supervision/web/finops.html /opt/supervision/web/finops.html.avant-bascule
python3 - <<'FIN_CORRECTIF'
import os, sys
INDEX = os.environ.get("PAGE_WEB", "/opt/supervision/web/index.html")
FINOPS = os.environ.get("PAGE_FINOPS", "/opt/supervision/web/finops.html")
BOUTON_CSS = (".bascule{display:inline-flex;align-items:center;gap:8px;padding:10px 18px;border-radius:999px;"
              "border:1px solid rgba(54,197,230,.45);background:rgba(54,197,230,.10);color:#9EE6F7;"
              "font-family:var(--mono);font-size:14px;letter-spacing:.08em;text-decoration:none;cursor:pointer;white-space:nowrap}\n"
              ".bascule:hover{background:rgba(54,197,230,.22)}\n")


def remplacer(texte, avant, apres, nom):
    if texte.count(avant) != 1:
        sys.exit(f"ERREUR : repere introuvable dans {nom}, rien n'a ete modifie.")
    return texte.replace(avant, apres)


i = open(INDEX).read()
f = open(FINOPS).read()
if 'class="bascule"' in i:
    print("Bouton deja installe, rien a faire.")
    sys.exit(0)

# Ecran principal : curseur visible + bouton vers la page des couts
i = remplacer(i, "overflow:hidden;cursor:none}", "overflow:hidden}", "l'ecran principal")
i = remplacer(i, ".mono{font-family:var(--mono)}", ".mono{font-family:var(--mono)}\n" + BOUTON_CSS, "l'ecran principal")
i = remplacer(i, '''  <div style="display:flex;align-items:center;gap:28px">
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">''',
              '''  <div style="display:flex;align-items:center;gap:28px">
    <a class="bascule" href="/finops">COÛTS &nbsp;›</a>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">''', "l'ecran principal")

# Page FinOps : bouton de retour + mise en page large pour l'ecran du serveur
f = remplacer(f, '''  <div class="sous"><a href="/">← Écran de supervision</a></div>''',
              '''  <a class="bascule" href="/">‹ &nbsp;SUPERVISION</a>''', "la page FinOps")
f = remplacer(f, "a{color:var(--accent)}", "a{color:var(--accent)}\n" + BOUTON_CSS +
              ".duo{display:grid;grid-template-columns:minmax(0,1fr);gap:18px}\n"
              "@media (min-width:1600px){main{max-width:1840px}.duo{grid-template-columns:minmax(0,1.25fr) minmax(0,1fr)}}",
              "la page FinOps")
f = remplacer(f, '''<section class="panneau">
  <div style="display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;align-items:baseline">
    <h2>Coût d'électricité''', '''<div class="duo">
<section class="panneau">
  <div style="display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;align-items:baseline">
    <h2>Coût d'électricité''', "la page FinOps")
f = remplacer(f, '''</section>

<section class="grille2">''', '''</section>
</div>

<section class="grille2">''', "la page FinOps")

open(INDEX, "w").write(i)
open(FINOPS, "w").write(f)
print("Bouton de bascule installe sur les deux pages, curseur visible.")
FIN_CORRECTIF
systemctl restart ecran-supervision.service
echo "TERMINE : l'ecran redemarre avec le bouton COUTS en haut a droite."
