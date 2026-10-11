# 4. Accès distant « zéro confiance » avec Tailscale

Script : `scripts/03-tailscale-partage.sh` (même méthode reprise dans tous les conteneurs)

## Le problème

Ouvrir des ports sur la box pour accéder à ses services depuis l'extérieur, c'est les exposer à tout Internet, en permanence. Les robots qui balaient les adresses IP trouveraient une interface Proxmox ou un partage SMB en quelques heures.

## La solution : aucun port ouvert

**Tailscale** crée un réseau privé chiffré (WireGuard) entre mes appareils : iPhone, iPad, PC, et le serveur et chacun de ses conteneurs. Chaque appareil s'authentifie avec mon compte ; les connexions sont établies de pair à pair, sans rien ouvrir sur la box.

C'est le modèle **zéro confiance** : on ne fait pas confiance au réseau (même le Wi-Fi de la maison), on authentifie chaque appareil.

## Mise en œuvre dans un conteneur LXC

Un conteneur non privilégié n'a pas accès par défaut au périphérique réseau virtuel `/dev/net/tun` dont Tailscale a besoin. Deux lignes dans sa configuration l'autorisent, et seulement lui :

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Chaque service rejoint ensuite le réseau avec son propre nom (`anto-jellyfin`, `anto-proxy`…), via `tailscale up --accept-dns=false` :

- `--accept-dns=false` : les serveurs gardent la box comme DNS et ne dépendent donc pas d'AdGuard, qu'ils hébergent eux-mêmes ;
- **expiration de clé désactivée** pour les machines du serveur, sinon elles se déconnecteraient tous les six mois.

## Partager sans tout ouvrir

Pour donner l'accès à Jellyfin à un ami, on partage **une seule machine** (`anto-jellyfin`) depuis la console Tailscale. Il ne voit rien d'autre du réseau : c'est une micro-segmentation.

## Équivalent cloud

Azure VPN Gateway ou Azure Bastion pour l'administration, points de terminaison privés pour les services : rien n'est publié sur Internet.
