# 3. Partage de fichiers SMB — conteneur 101 « partage »

Script : `scripts/02-creer-partage.sh` · Configuration : `configs/conteneurs/smb.conf`

## Rôle

Déposer et récupérer photos, films et papiers personnels depuis un PC Windows (`\\192.168.1.26\photos` à la maison) ou depuis l'app Fichiers de l'iPhone. En déplacement, on utilise le nom Tailscale du conteneur à la place de son adresse.

## Choix de configuration

| Réglage | Pourquoi |
|---|---|
| `server min protocol = SMB3` | SMB1 et SMB2 sont obsolètes et vulnérables ; à distance, le trafic est de toute façon chiffré par Tailscale |
| `map to guest = never` | Aucun accès anonyme |
| `disable netbios = yes`, port 445 seul | Moins de services exposés, moins de surface d'attaque |
| `valid users = anto` | Un compte nommé par partage, mot de passe saisi en masqué à l'installation |
| `vfs objects = fruit streams_xattr` | Compatibilité avec l'app Fichiers d'iOS et macOS |

## Le partage « papiers » (documents personnels)

Ajouté avec `scripts/14-ajout-papiers.sh` pour les pièces d'identité, attestations et certificats :

- dossier en `700` : seul `anto` y accède, et il n'est monté dans **aucun** autre conteneur (ni Jellyfin, ni Immich) ;
- `server smb encrypt = desired` : chiffrement SMB3 dès que l'appareil le permet, même sur le réseau local ;
- `veto files` : les fichiers exécutables et scripts (`.exe`, `.bat`, `.js`, `.ps1`…) sont refusés ;
- copié chaque nuit sur le Barracuda, avec corbeille de 90 jours.

Limite : les fichiers ne sont pas chiffrés sur le disque lui-même ; un vol du serveur les exposerait.

## Droits

Les dossiers appartiennent à `101000:101000` sur l'hôte, c'est-à-dire à l'utilisateur `anto` (UID 1000) **dans** le conteneur non privilégié. Le conteneur n'a accès qu'aux trois dossiers montés, rien d'autre du serveur.

## Ressources

1 cœur, 512 Mo de mémoire, 4 Go de disque : Samba est très léger. C'est aussi ce qui le rend économique dans la [page FinOps](11-finops.md).

## Équivalent cloud

Azure Files (partage SMB managé), accessible par un point de terminaison privé plutôt qu'exposé sur Internet.
