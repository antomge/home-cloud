# 7. Tri automatique des photos

Script : `scripts/07-installer-tri-photos.sh` · Code : `services/tri-photos.py`

## Le besoin

Déposer ses photos en vrac depuis l'iPhone ou le PC, et les retrouver rangées par **année puis par mois**, sans rien faire.

## Fonctionnement

Toutes les 5 minutes (minuteur systemd), les photos et vidéos posées **à la racine** du dossier `photos` sont rangées dans `AAAA/MM - Mois/` :

1. **date de prise de vue** lue dans les métadonnées EXIF ou QuickTime avec `exiftool` (une seule invocation pour tous les fichiers) ;
2. sinon, une date trouvée **dans le nom du fichier** (`IMG-20231005-WA0001.jpg`) ;
3. en dernier recours, la date de modification.

## Garde-fous

| Risque | Protection |
|---|---|
| Déplacer une photo encore en cours d'envoi | Un fichier modifié il y a moins de 2 minutes est ignoré jusqu'au passage suivant |
| Perdre un fichier | Rien n'est jamais supprimé |
| Doublon exact (même empreinte SHA-256) | Déplacé dans `_doublons/` |
| Deux photos différentes avec le même nom | La seconde reçoit un suffixe ` (1)` |
| Désorganiser des albums existants | Les sous-dossiers ne sont jamais touchés |
| Deux tris en même temps | Verrou (`flock`) |
| Gêner les autres services | Priorité processeur et disque minimale (`Nice=19`, `IOSchedulingClass=idle`) |

Chaque déplacement est écrit dans `/var/log/tri-photos.log`, avec l'origine de la date utilisée.

## Effet sur la copie nocturne

Pour `rsync`, une photo rangée « disparaît » de la racine et « apparaît » dans un sous-dossier : l'ancien emplacement passe une fois dans la corbeille du Barracuda (90 jours). C'est le prix, temporaire, de la suppression réversible.
