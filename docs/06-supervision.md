# 6. Supervision et écran du serveur

Scripts : `scripts/05-installer-ecran.sh` (collecteur, page, relevés SMART) et `scripts/06-installer-affichage.sh` (affichage HDMI)
Code : `supervision/collecteur.py`, `supervision/index.html`

![Écran de supervision](../captures/ecran-supervision.jpg)

## Architecture

```
/proc, capteurs, disques ─┐
API Proxmox (lecture seule)┤
API Jellyfin              ├─► collecteur.py ──► /api/etat (JSON) ──► page web ──► écran HDMI (kiosque)
tailscale status          ┤    127.0.0.1:8088                                └──► navigateur (via Tailscale)
relevés SMART, copie,     ┘
sauvegardes, FinOps
```

### Le collecteur — `collecteur.py`

Un seul fichier Python, **bibliothèque standard uniquement** (rien à installer, rien à mettre à jour). Deux boucles :

- **chaque seconde** : charge processeur (`/proc/stat`), mémoire, température (`coretemp`), fréquence de chaque cœur (`cpufreq`), débit réseau ;
- **toutes les 15 secondes** : espace disque, médiathèque et lectures en cours (API Jellyfin), conteneurs (API Proxmox), appareils Tailscale en ligne, santé SMART, état de la copie et des sauvegardes, synthèse FinOps.

Il n'écoute que sur `127.0.0.1` : rien n'est exposé sur le réseau.

### Moindre privilège pour les API

- **Proxmox** : un utilisateur dédié `supervision@pve` avec un jeton qui n'a que le rôle **PVEAuditor** (lecture seule). Même volé, ce jeton ne permet de rien modifier.
- **Jellyfin** : une clé d'API dédiée, envoyée avec l'en-tête moderne `Authorization: MediaBrowser Token="…"`.
- Les deux secrets sont dans `/etc/supervision.env`, en `640 root:supervision`, lus par un service qui tourne sous un compte sans droits (`supervision`). Modèle : `configs/supervision.env.exemple`.

### La page — `index.html`

Une page conçue pour un écran 1920 × 1080 et mise à l'échelle automatiquement, dans un style « salle de contrôle » : indicateurs principaux, courbes sur 2 minutes (charge, fréquence en GHz avec le plafond si le processeur est bridé, sortie réseau), stockage, Jellyfin, tableau SMART, état des services et des conteneurs. Un bouton **COÛTS** bascule vers la [page FinOps](11-finops.md).

## Affichage sur l'écran HDMI — `06-installer-affichage.sh`

Pas de bureau complet : **cage** (un compositeur Wayland « kiosque ») lance **Chromium en plein écran** sur la page, sur le terminal `tty1`, au démarrage.

- compte dédié `kiosque` **sans mot de passe ni droits d'administration** ;
- session PAM propre au service ; redémarrage automatique en cas de plantage.

## Accès à distance

`tailscale serve --bg --http=80 8088` publie la page sur l'adresse Tailscale du serveur, et seulement là ; elle est aussi accessible en HTTPS par le [proxy](10-proxy-https.md) : `https://tableau.maison.<domaine>`.

## Relevés SMART — `services/releve-smart.py`

Toutes les 10 minutes : température, heures de fonctionnement, secteurs réalloués ou en attente pour les disques durs, volume écrit rapporté à l'endurance pour le SSD. Les seuils « À surveiller » et « Critique » sont calculés et affichés sur l'écran.

## Équivalent cloud

Azure Monitor (métriques et journaux), classeurs Azure (tableaux de bord), identités en lecture seule pour la collecte.
