# 5. Jellyfin et transcodage matériel — conteneur 102

Script : `scripts/04-creer-jellyfin.sh`

## Rôle

Regarder ses films partout : sur la télé, le PC, ou l'iPhone avec l'application Streamyfin, y compris en 5G via Tailscale.

## Transcodage matériel (Intel Quick Sync)

Quand la connexion est trop faible pour le fichier d'origine (en 4G par exemple), Jellyfin **réencode** la vidéo à la volée dans une qualité plus légère. Fait par le processeur, c'est très lourd ; fait par la puce graphique intégrée UHD 630 (Quick Sync), c'est presque gratuit.

Pour la donner au conteneur, on transmet uniquement le périphérique de rendu, avec le groupe `render` du conteneur :

```
dev0: /dev/dri/renderD128,gid=992
```

Résultat vérifié pendant un transcodage : décodage et encodage H.264/HEVC par la puce graphique, processeur inoccupé à environ 78 %.

## Choix de configuration

| Réglage | Pourquoi |
|---|---|
| Films montés en **lecture seule** (`ro=1`) | Jellyfin ne peut pas modifier ni supprimer la médiathèque |
| Dossier de transcodage sur le WD (`/mnt/wd/transcodage-jellyfin`) | Les fichiers temporaires du transcodage usent le SSD : on les envoie sur le disque dur |
| 4 cœurs, 3 Go de mémoire | Marge pour plusieurs lectures simultanées |
| Dépôt officiel `repo.jellyfin.org` | `jellyfin-ffmpeg` inclut le pilote Intel iHD |

Le dossier de transcodage n'apparaît plus dans l'interface de Jellyfin 10.12 : il est réglé directement dans `/etc/jellyfin/encoding.xml` (`TranscodingTempPath`).

## Qualité en mobilité

En 4G, le débit de streaming est limité vers 720p à environ 4 Mbit/s (≈ 1,8 Go par heure), pour ménager un forfait de 250 Go.

## Accès

`https://jellyfin.maison.<domaine>` via le [proxy HTTPS](10-proxy-https.md), depuis n'importe quel appareil Tailscale.
