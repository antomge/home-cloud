# Sécurité

## Principes appliqués

| Principe | Mise en œuvre |
|---|---|
| **Aucune exposition publique** | Zéro port ouvert sur la box ; accès distant uniquement par Tailscale |
| **Zéro confiance** | Chaque appareil s'authentifie ; le réseau local n'est pas considéré comme sûr |
| **Moindre privilège** | Conteneurs non privilégiés ; médiathèques en lecture seule pour Jellyfin et Immich ; jeton Proxmox en lecture seule (PVEAuditor) ; jeton Cloudflare limité au DNS d'une seule zone ; compte `kiosque` sans droits pour l'écran ; Caddy sous un compte dédié |
| **Micro-segmentation** | Un ami peut recevoir l'accès à Jellyfin seul, sans voir le reste du réseau |
| **Défense en profondeur** | SMB3 minimum, pas d'invité, NetBIOS coupé ; DNS amont chiffré ; HTTPS de bout en bout côté client |
| **Secrets hors du code** | Mots de passe saisis en masqué ; secrets dans des fichiers `640` lus par des comptes dédiés ; jamais dans ce dépôt |

## Gestion des secrets

| Secret | Où il vit | Qui peut le lire |
|---|---|---|
| Clé d'API Jellyfin, jeton Proxmox | `/etc/supervision.env` (hôte) | root, groupe `supervision` |
| Jeton Cloudflare | `/etc/caddy/cloudflare.env` (conteneur proxy) | root, groupe `caddy` |
| Mot de passe de la base Immich | `/opt/immich/.env` (conteneur immich) | root |
| Mots de passe Samba | base Samba du conteneur partage | root |

Le dépôt ne contient que des modèles `.exemple`. Le script `scripts/exporter-home-cloud.sh`, qui a servi à extraire les fichiers du serveur pour ce dépôt, n'emporte aucun de ces fichiers et cherche les motifs de secrets avant de créer l'archive. Les identifiants matériels (numéros de série, adresses MAC), les adresses Tailscale et le nom de domaine ont aussi été remplacés par des valeurs d'exemple.

## Logiciels malveillants dans un dossier partagé

Un fichier piégé déposé dans un partage peut infecter l'ordinateur de la personne qui l'ouvre ; le serveur, lui, ne l'exécute pas. Les protections possibles :

- montages **en lecture seule** partout où l'écriture n'est pas nécessaire (déjà fait pour Jellyfin et Immich) ;
- dans Samba, `veto files` pour refuser les extensions exécutables (`.exe`, `.scr`, `.js`, `.vbs`…) ;
- antivirus (ClamAV) sur les dossiers partagés ;
- un dossier partagé par personne plutôt qu'un dossier commun.

## Points d'attention connus

- **AdGuard est un point de défaillance unique** pour la résolution de noms des appareils Tailscale.
- **Tout est dans une seule machine** : pas de haute disponibilité, pas de copie hors site.
- La rotation des clés d'API (Jellyfin, Proxmox, Cloudflare) est manuelle.
