# 2. Stockage et sauvegardes

## Préparation des disques — `scripts/01-preparer-disques.sh`

- Les disques sont repérés **par numéro de série**, jamais par leur nom `/dev/sdX` qui peut changer d'un démarrage à l'autre. Le script refuse de continuer si un disque cible est le disque système ou s'il a une partition montée, et demande de taper `OUI` avant d'effacer quoi que ce soit.
- Table GPT, une partition, **ext4 avec `-m 0`** : la réserve de 5 % pour root (200 Go sur 4 To) n'a pas de sens sur un disque de données.
- Montage dans `/etc/fstab` **par UUID**, avec `noatime` (pas d'écriture à chaque lecture) et `nofail` (le serveur démarre même si un disque manque).

| Disque | Montage | Contenu |
|---|---|---|
| WD Red Plus 4 To | `/mnt/wd` | `photos/`, `films/`, `papiers/`, `immich/`, `sauvegardes/`, `transcodage-jellyfin/` |
| Barracuda 2 To | `/mnt/barracuda` | `copie-photos/` et `copie-papiers/` (chacun avec `actuel` et `corbeille`) |

## Comment les conteneurs voient les données

Les dossiers du WD sont **montés dans les conteneurs** (`mp0`, `mp1`… dans `configs/lxc/`). Un même fichier est donc visible par plusieurs services, avec des droits différents :

| Dossier | partage | jellyfin | immich |
|---|---|---|---|
| `photos` | lecture / écriture | — | **lecture seule** |
| `films` | lecture / écriture | **lecture seule** | — |

Jellyfin et Immich ne peuvent ni modifier ni supprimer vos fichiers : c'est le **moindre privilège** appliqué au stockage.

## Deux niveaux de protection

### 1. Instantanés des conteneurs (Proxmox)

Tâche `sauvegarde-nuit` (`configs/jobs.cfg`) : chaque nuit à **2 h**, tous les conteneurs sont sauvegardés en mode *snapshot* (sans les arrêter), compressés en zstd, sur le stockage `sauvegardes` du WD.
Rétention : **7 sauvegardes quotidiennes + 4 hebdomadaires**.

Elles protègent le **système** des conteneurs (configuration, base de données Immich), pas les photos et films, qui sont sur des montages.

### 2. Copie des photos avec corbeille — `services/copie-photos.sh`

Chaque nuit à **3 h**, `rsync` recopie `/mnt/wd/photos` et `/mnt/wd/papiers` vers le Barracuda :

- un fichier supprimé ou modifié sur le WD n'est pas perdu : l'ancienne version part dans `corbeille/<date>/` et y reste **90 jours** (équivalent de la *suppression réversible* du stockage Azure) ;
- **sécurité anti-catastrophe** : si le dossier source est vide alors que la copie contient des fichiers (disque mal monté, effacement massif), la copie est **annulée** au lieu d'effacer la copie ;
- le résultat est écrit dans un fichier d'état affiché sur l'écran de supervision.

Installation (unités dans `services/systemd/`) :

```bash
install -m 755 services/copie-photos.sh /usr/local/sbin/
cp services/systemd/copie-photos.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now copie-photos.timer
```

## RPO, RTO et règle 3-2-1

- **RPO** (perte de données maximale) : 24 h pour les photos et les conteneurs.
- **RTO** (temps de remise en service) : quelques minutes pour restaurer un conteneur depuis l'interface Proxmox.
- **3-2-1** : 3 copies, sur 2 supports, dont 1 hors site. Ici : 2 copies des photos et des papiers, sur 2 disques, **mais aucune hors site**. C'est la limite principale du projet, assumée.

## Surveillance de la santé des disques

`services/releve-smart.py` lit les attributs SMART toutes les 10 minutes. Pour le SSD, l'indicateur retenu est le **volume écrit rapporté à l'endurance garantie** (160 To pour le Kingston A400), plus fiable que l'attribut « durée de vie » de ce modèle, dont l'interprétation varie selon les outils (voir [leçons apprises](lecons-apprises.md)).
