# 8. Immich — galerie photos avec recherche par contenu (conteneur 103)

Script : `scripts/08-creer-immich.sh`

## Rôle

Retrouver ses photos par leur contenu (« plage », « chat », « anniversaire »), par visage ou par lieu, comme dans l'app Photos de l'iPhone, mais sur son propre serveur. La recherche utilise un **modèle d'analyse multilingue**, pour pouvoir chercher en français.

## Architecture

Immich est distribué sous forme de plusieurs conteneurs Docker (serveur, apprentissage automatique, PostgreSQL, Redis). Ils tournent **dans un conteneur LXC non privilégié**, ce qui demande les options `nesting=1,keyctl=1`.

| Élément | Emplacement | Pourquoi |
|---|---|---|
| Photos | `/mnt/wd/photos` monté en **lecture seule** | Immich lit la photothèque existante sans pouvoir la modifier |
| Miniatures, aperçus vidéo, sauvegardes de la base | `/mnt/wd/immich` | Données volumineuses et régénérables : sur le disque dur |
| Base PostgreSQL | dans le conteneur, sur le SSD | Petite, mais très sollicitée en lecture/écriture aléatoire |
| Mot de passe de la base | `/opt/immich/.env`, généré à l'installation, lisible par root | Jamais saisi ni affiché |

## Ressources

4 cœurs et 7 Go de mémoire au maximum : ce sont des **plafonds**, pas des réservations. L'analyse initiale de la photothèque (visages, contenu) est le moment le plus gourmand ; on le voit très bien sur la [page FinOps](11-finops.md), où Immich est le premier consommateur pendant cette phase.

## Accès

`https://immich.maison.<domaine>` via le [proxy HTTPS](10-proxy-https.md), dans le navigateur ou l'application mobile Immich.
