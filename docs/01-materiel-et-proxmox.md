# 1. Matériel et hyperviseur Proxmox

## Le matériel

| Pièce | Modèle | Rôle |
|---|---|---|
| Processeur | Intel Core i5-9500 (6 cœurs, puce graphique UHD 630) | Calcul + transcodage vidéo matériel (Quick Sync) |
| Mémoire | 2 × 8 Go DDR4 (G.Skill Aegis), 2666 MHz en double canal | 16 Go partagés entre les conteneurs |
| Carte mère | MSI H310M PRO-VDH PLUS | 4 ports SATA, sortie HDMI pour l'écran de supervision |
| Disque système | SSD Kingston A400 480 Go | Proxmox + disques des conteneurs |
| Disque de données | WD Red Plus 4 To (CMR) | Photos, films, données Immich, sauvegardes |
| Disque de copie | Seagate Barracuda 2 To | Copie nocturne des photos |
| Réseau | Switch TP-Link TL-SG605E (Gigabit, gère les VLAN) | Liaison 1 Gbit/s avec la box |

Le PC existait déjà : seuls le processeur, le WD Red et le switch ont été achetés (343,96 €). Le WD Red Plus a été choisi pour sa technologie **CMR** (enregistrement classique), plus fiable en écritures continues que le SMR des disques d'entrée de gamme.

**Réglages du BIOS :** profil mémoire XMP, virtualisation activée, démarrage UEFI, et **redémarrage automatique après une coupure de courant**, indispensable pour un serveur.

## Pourquoi un hyperviseur ?

Installer tous les services directement sur un seul Linux, c'est mélanger leurs dépendances, leurs droits et leurs pannes. **Proxmox VE** (Debian + KVM + LXC) permet au contraire de découper la machine en **conteneurs isolés**, chacun avec ses propres ressources, comme des machines virtuelles dans le cloud :

- une mise à jour ratée de Jellyfin ne touche pas le partage de fichiers ;
- chaque service a son adresse IP, sa mémoire et son nombre de cœurs ;
- les sauvegardes et la restauration se font conteneur par conteneur.

## Conteneurs LXC plutôt que machines virtuelles

Un conteneur LXC partage le noyau de l'hôte : il démarre en deux secondes et ne consomme presque rien au repos. Tous les conteneurs sont **non privilégiés** : le `root` d'un conteneur correspond à l'utilisateur `100000` de l'hôte. Même en cas de compromission, il n'a aucun droit sur le serveur. C'est ce décalage d'UID qui explique les droits `101000:101000` sur les dossiers partagés (l'utilisateur `1000` du conteneur).

## Installation

- Proxmox VE 9.2 sur le SSD, système de fichiers ext4 + LVM ; l'espace des conteneurs est un *thin pool* (`local-lvm`).
- Dépôt « enterprise » désactivé, dépôt « no-subscription » activé.
- Services de haute disponibilité (`pve-ha-lrm`, `pve-ha-crm`) désactivés : inutiles sur un seul nœud, et ils écrivent en permanence sur le SSD.
- Adresse fixe `192.168.1.33` réservée dans la box (bail DHCP statique), nom `serveur.home.arpa`.

## Plan d'adressage

| Plage | Usage |
|---|---|
| `192.168.1.1` | Box (passerelle) |
| `192.168.1.10–19` | Appareils personnels |
| `192.168.1.26–31` | Conteneurs du serveur (baux statiques) |
| `192.168.1.33` | Hôte Proxmox |

Toutes les adresses des conteneurs sont **réservées dans la box** : le proxy inverse contacte les services par leur IP, une adresse qui change le casserait.
