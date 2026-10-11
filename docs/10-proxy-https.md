# 10. Proxy inverse HTTPS — conteneur 104 « proxy »

Script : `scripts/10-creer-proxy.sh` · Configuration : `configs/conteneurs/Caddyfile`

## Avant / après

| Avant | Après |
|---|---|
| `http://anto-jellyfin:8096` | `https://jellyfin.maison.<domaine>` |
| `https://serveur:8006` + avertissement de certificat | `https://proxmox.maison.<domaine>` avec cadenas valide |
| Un port différent par service | Une seule porte d'entrée, en HTTPS |

## Le chemin d'une requête

```
iPhone ──(1) jellyfin.maison.<domaine> ?──► AdGuard ──► « 100.x.x.x (le proxy) »
iPhone ──(2) HTTPS via Tailscale──────────► Caddy ──► 192.168.1.27:8096 (Jellyfin)
```

## Le certificat : défi DNS-01

Let's Encrypt doit vérifier que le domaine m'appartient. La méthode habituelle (une page web sur le port 80) est impossible : **aucun port n'est ouvert**. Caddy utilise donc le **défi DNS** : il crée un enregistrement TXT temporaire chez Cloudflare grâce à un jeton d'API, Let's Encrypt le lit, puis Caddy le supprime.

- Un **certificat générique** `*.maison.<domaine>` couvre tous les services : leurs noms n'apparaissent pas dans les journaux publics de transparence des certificats.
- Le renouvellement est automatique.
- Caddy est téléchargé avec le module `caddy-dns/cloudflare`.

## Le jeton Cloudflare : moindre privilège

- Permissions : `Zone → DNS → Edit` et `Zone → Zone → Read`, **sur une seule zone**. Il ne peut rien faire d'autre sur le compte.
- Saisi en masqué, vérifié auprès de l'API Cloudflare, puis transmis au conteneur par l'entrée standard : il n'est jamais affiché ni écrit dans une commande enregistrée.
- Stocké dans `/etc/caddy/cloudflare.env` en `640 root:caddy`. Modèle : `configs/cloudflare.env.exemple`.

## Détails techniques

- Caddy tourne sous un compte système `caddy`, avec la seule capacité `CAP_NET_BIND_SERVICE`.
- L'interface Proxmox utilise un certificat auto-signé : vérification TLS désactivée **uniquement** entre le proxy et Proxmox, sur le réseau local.
- Le tableau de bord est publié par `tailscale serve`, qui ne répond qu'à son propre nom : Caddy réécrit l'en-tête `Host` (voir [leçons apprises](lecons-apprises.md)).
- Le script retrouve seul les adresses des services à partir du nom de leur conteneur, puis teste chaque site avant de rendre la main.

## Équivalent cloud

Azure Application Gateway (point d'entrée unique, terminaison TLS), certificats gérés et Key Vault, identité managée limitée à une zone DNS.
