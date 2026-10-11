# 11. FinOps — mesurer, imputer, comparer

Script : `scripts/11-installer-finops.sh` (+ `12-ajout-bascule.sh` pour le bouton de l'écran)
Code : `services/finops-releve.py`, `services/finops-azure.py`, `supervision/finops.html` · Hypothèses : `configs/finops.json`

La démarche FinOps tient en trois mots : **informer** (savoir ce que l'on dépense), **optimiser**, **opérer**. Cette page couvre surtout le premier : rendre le coût visible, par service, avec une méthode explicite.

## 1. Mesurer la consommation

Chaque minute, `finops-releve.py` lit les **compteurs d'énergie du processeur** (Intel RAPL, `/sys/class/powercap/intel-rapl:0/energy_uj`), en gérant le retour à zéro du compteur. La puissance à la prise est ensuite estimée :

```
P_prise = (P_processeur mesurée + 14 W autres composants) / 0,85 (rendement de l'alimentation)
```

Les 14 W (deux disques durs, SSD, carte mère, mémoire, ventilateurs) sont une **estimation**, écrite noir sur blanc dans les hypothèses et à confronter un jour à une prise wattmètre. Si RAPL n'est pas disponible, la puissance du processeur est estimée d'après sa charge, et la page l'indique.

## 2. Imputer le coût aux services (showback)

Chaque minute d'énergie est découpée en deux parts, chacune avec sa **clé de répartition** :

| Part | Contenu | Clé de répartition | Analogie cloud |
|---|---|---|---|
| **Variable** | Processeur au-dessus de sa puissance de repos | Temps processeur réellement consommé par chaque conteneur (`/sys/fs/cgroup/lxc/<id>/cpu.stat`), le reste revenant à l'hôte | Facturation à l'usage |
| **Fixe** | Repos du processeur, disques, carte mère | Mémoire réservée par chaque conteneur (l'hôte Proxmox compte pour 2 Go) | Capacité réservée, payée même inutilisée |

La puissance de repos est la plus petite minute mesurée sur les 7 derniers jours : le partage s'affine avec le temps.

**Limite connue :** le transcodage de Jellyfin passe par la puce graphique, dont l'énergie est dans le compteur du processeur ; la clé « temps processeur » le sous-estime un peu.

## 3. Le prix

- **0,2001 €/kWh** : Tarif Bleu EDF option Base (6 kVA), en vigueur depuis le 1ᵉʳ août 2026.
- **L'abonnement n'est pas imputé** : il serait payé même sans serveur. On ne facture à un service que ce qu'il fait réellement varier (coût marginal).

## 4. Coût total de possession

| Poste | Traitement |
|---|---|
| Électricité | Puissance moyenne mesurée × 730 h × prix du kWh |
| Matériel acheté pour le projet (343,96 €) | Amorti sur 36 mois → 9,55 €/mois |
| Pièces déjà possédées (boîtier, carte mère, mémoire, SSD, Barracuda) | **Coûts irrécupérables** : hors calcul |
| Nom de domaine | Prix annuel ÷ 12, à renseigner dans `configs/finops.json` |

## 5. Comparaison avec Azure

`finops-azure.py` interroge chaque lundi l'**API publique des prix de détail Azure** (`prices.azure.com`, sans compte ni clé) :

- VM **Standard_B4ms** (4 vCPU, 16 Go), Linux, tarif à l'usage, France Centre ;
- disque **HDD standard S50** (4 To).

Les filtres excluent les prix Windows, Spot et « basse priorité ». En cas d'échec, les derniers prix connus sont conservés avec un avertissement.

### Résultat (octobre 2026)

| | Par mois |
|---|---|
| Home Cloud : électricité (≈ 22 W à la prise) | ≈ 3,2 € |
| Home Cloud : matériel amorti | 9,55 € |
| **Home Cloud : total** | **≈ 13 €** |
| Azure : VM B4ms | 121,40 € |
| Azure : disque S50 | 138,75 € |
| **Azure : total** | **≈ 260 €** |

### Lecture critique

- La comparaison **avantage Azure** : ni la sortie de données (streaming), ni les sauvegardes, ni l'équivalent du transcodage matériel ne sont comptés.
- Elle avantage aussi le serveur maison : ni haute disponibilité, ni copie hors site, ni temps passé à l'administrer.
- Les leviers d'optimisation sur Azure seraient : **réservation** sur 1 ou 3 ans, stockage **Blob froid** pour les photos au lieu d'un disque provisionné, **arrêt de la VM** la nuit, et redimensionnement d'après la charge mesurée.

## La page

`https://tableau.maison.<domaine>/finops`, accessible aussi depuis l'écran du serveur par le bouton **COÛTS** :

- puissance actuelle, coût du jour, du mois (avec projection) et de l'année ;
- coût par jour sur 30 jours, empilé par service, avec infobulles ;
- tableau d'imputation par service (puissance actuelle, énergie, coût, part, part variable) ;
- coût total de possession face à l'équivalent Azure ;
- méthode et hypothèses, affichées en toutes lettres.

Les couleurs des services viennent d'une palette catégorielle validée pour le daltonisme et le contraste sur fond sombre ; chaque couleur est doublée d'un libellé.
